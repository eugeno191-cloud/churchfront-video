import Foundation
import Combine
import CueATEM

// Bumper videos played by FreeShow, through its REST API (Settings > Connections in
// FreeShow, port 5506): POST {"action": ...} as JSON. A password, if one is set in FreeShow,
// goes as a Bearer token.

enum FreeShowError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case password
    case didNotStart

    var description: String {
        switch self {
        case .unreachable(let why): return "FreeShow didn't answer: \(why). Check its address in Setup, and that its API is on (FreeShow: Settings > Connections)."
        case .password: return "FreeShow turned down the password. Check it in Setup, or in FreeShow's Settings > Connections."
        case .didNotStart: return "FreeShow didn't start the video. Check the file's path on the FreeShow computer."
        }
    }
}

final class FreeShowClient {
    let host: String
    let port: Int
    private let password: () -> String?
    private let session: URLSession

    init(host: String, port: Int, session: URLSession? = nil, password: @escaping () -> String?) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = port
        self.password = password
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 3
            self.session = URLSession(configuration: c)
        }
    }

    /// Sends one action. Returns what FreeShow answered: the "data" of its {"action", "data"}
    /// answer, or nil for an empty answer.
    @discardableResult
    func send(_ action: String, _ extra: [String: Any] = [:]) async throws -> Any? {
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(port)/") else { throw FreeShowError.unreachable("no address set") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let p = password(), !p.isEmpty { req.setValue("Bearer \(p)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: extra.merging(["action": action]) { a, _ in a })
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw FreeShowError.unreachable(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw FreeShowError.password }
        if code == 204 || data.isEmpty { return nil }
        guard (200..<300).contains(code) else { throw FreeShowError.unreachable("it answered \(code)") }
        let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        // FreeShow answers {"action": "...", "data": value}; older versions sent the value alone.
        if let d = json as? [String: Any], d["action"] != nil { return d["data"] }
        return json
    }

    /// Plays a video file once, with its sound (FreeShow loops and mutes by default).
    func play(_ path: String) async throws {
        try await send("play_media", ["path": path, "data": ["loop": false, "muted": false]])
    }

    /// Seconds left in the video playing now; 0 when none is.
    func timeLeft() async throws -> Double {
        let v = try await send("get_playing_video_time_left")
        if let d = v as? Double { return max(0, d) }
        if let i = v as? Int { return Double(max(0, i)) }
        if let s = v as? String, let d = Double(s) { return max(0, d) }
        return 0
    }

    /// The file the output is playing as its background now, if FreeShow says (nil when none,
    /// or from a FreeShow too old to say).
    /// `output` (an output id) asks about that output; nil asks about the first unlocked one.
    func backgroundPath(output: String? = nil) async throws -> String? {
        let out = try await send("get_output", output.map { ["id": $0] } ?? [:]) as? [String: Any]
        return (out?["background"] as? [String: Any])?["path"] as? String
    }

    /// Whether `path` is what's playing: a looping background video also has "time left", so
    /// that alone doesn't show the bumper has started. A FreeShow that doesn't say what's
    /// playing is taken at its word.
    func isPlaying(_ path: String) async throws -> Bool {
        guard try await timeLeft() > 0 else { return false }
        guard let now = try await backgroundPath() else { return true }
        return Self.same(now, path)
    }

    static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    func clearBackground() async throws { try await send("clear_background") }

    /// Takes the slide (verses, lyrics) and overlays off the active outputs, so only the
    /// bumper shows. Locked outputs keep theirs.
    func clearWords() async throws {
        try await send("clear_slide")
        try await send("clear_overlays")
    }

    /// Locks an output (by id) so new content skips it, or unlocks it.
    func lock(_ outputId: String, _ locked: Bool) async throws {
        try await send("lock_output", ["outputId": outputId, "value": locked])
    }

    /// Sets an output's style (output by name or id, style by id; "" for no style).
    func setStyle(output: String, style: String) async throws {
        try await send("change_output_style", ["outputId": output, "styleId": style])
    }
}

/// FreeShow's outputs as its settings file on this Mac has them, for filling in Setup when
/// FreeShow runs on the same Mac. Nil when there's no FreeShow here.
enum LocalFreeShow {
    struct Output { let id: String; let name: String; let style: String; let ndi: Bool }

    static func outputs() -> [Output]? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freeshow/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outs = json["outputs"] as? [String: [String: Any]] else { return nil }
        return outs.compactMap { id, o in
            guard o["enabled"] as? Bool != false, o["stageOutput"] == nil || o["stageOutput"] is NSNull else { return nil }
            return Output(id: id, name: o["name"] as? String ?? id, style: o["style"] as? String ?? "", ndi: o["ndi"] as? Bool ?? false)
        }.sorted { $0.name < $1.name }
    }
}

/// Plays a bumper: FreeShow starts the video, the switcher fades to FreeShow's input once it's
/// running, and fades back to what was Live when it's about to end (or when stopped). Next is
/// put back as it was. If the video never starts, the switcher isn't touched.
///
/// Another bumper can be pressed while one plays: it takes over on the stream with no fade.
/// With stream only, once the bumper is running the stream output is locked on it and the
/// projector is unlocked, so slides can change on the projector while the bumper plays.
final class BumperPlayer: ObservableObject {
    static let shared = BumperPlayer()

    enum Phase: Equatable { case idle, starting, playing, ending }

    @Published private(set) var phase: Phase = .idle
    /// The bumper playing (or starting, or ending).
    @Published private(set) var current: Bumper?
    @Published private(set) var timeLeft: Double?
    @Published var problem: String?
    /// Stream only: the stream output is locked on the bumper and the projector is free.
    @Published private(set) var projectorFree = false

    private let booth: Booth
    private let session: URLSession?
    private let password: () -> String?
    private let setupOverride: (() -> FreeShowSetup)?
    /// Bumped to call off whatever the play loop is doing (Stop, or another bumper).
    private var run = 0
    /// Runs that another bumper took over from: they leave everything to it.
    private var replaced = Set<Int>()
    private var returnTo: (live: Int?, next: Int?) = (nil, nil)
    /// While a stream-only bumper runs: what was changed in FreeShow, to put back.
    private var changed: (locked: [String], style: (output: String, id: String)?) = ([], nil)

    /// `setup` replaces the app's setup (for tests, which must never touch the real setup file).
    init(booth: Booth = .shared, session: URLSession? = nil,
         password: @escaping () -> String? = { SavedLogin.freeshow.load()?.password },
         setup: (() -> FreeShowSetup)? = nil) {
        self.booth = booth
        self.session = session
        self.password = password
        self.setupOverride = setup
    }

    var setup: FreeShowSetup { setupOverride?() ?? booth.store.config.freeshow }
    var client: FreeShowClient? {
        setup.host.isEmpty ? nil : FreeShowClient(host: setup.host, port: setup.port, session: session, password: password)
    }

    /// How long FreeShow gets to start a video before the bumper gives up (the switcher untouched).
    static let startWait = 15.0

    /// How long the switcher's fade takes, in seconds (its mix rate, at 30 frames a second).
    var fadeSeconds: Double { Double(booth.atem.state.mixRate[booth.me] ?? 30) / 30 }

    /// Plays a bumper, or switches to it if another is playing. Calls back on the main thread
    /// once it's on air (nil) or with what went wrong.
    func play(_ b: Bumper, started: ((String?) -> Void)? = nil) {
        guard let client else { started?("FreeShow isn't set up. Add its address in Setup."); return }
        let switching: Bool
        switch phase {
        case .idle: switching = false
        case .starting, .playing:
            if b == current { started?("\(b.name) is already playing."); return }
            switching = true
            replaced.insert(run)
        case .ending: started?("A bumper is just ending. Try again in a moment."); return
        }
        let atem = booth.atem, me = booth.me
        run += 1
        let r = run
        if !switching { returnTo = (atem.state.program[me], atem.state.preview[me]) }
        current = b; phase = .starting; timeLeft = nil; problem = nil
        Task { @MainActor in await self.perform(b, r, client, switching: switching, started: started) }
    }

    @MainActor
    private func perform(_ b: Bumper, _ r: Int, _ client: FreeShowClient, switching: Bool, started: ((String?) -> Void)?) async {
        let atem = booth.atem, me = booth.me, s = setup, input = s.input
        // The caller hears exactly once: on air, or why not.
        var told = false
        func tell(_ why: String?) { if !told { told = true; started?(why) } }
        do {
            // Switching: the stream output takes new content again (the projector stays out).
            if switching { await takeStreamBack(client) } else { try await prepare(client) }
            if replaced.contains(r) { tell("Another bumper took over."); return }
            try await client.play(b.path)
            // Wait for this video to be running before anything goes to air. A long file can
            // take FreeShow several seconds to load (a 5-minute one took about 4), and a
            // looping background has time left too, so check it's this file.
            var left = 0.0
            for _ in 0..<Int(Self.startWait / 0.2) {
                if r != run { break }
                if try await client.isPlaying(b.path) { left = try await client.timeLeft(); if left > 0 { break } }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if replaced.contains(r) { tell("Another bumper took over."); return }
            guard r == run else { tell("Stopped before it went on air."); return }
            guard left > 0 else { throw FreeShowError.didNotStart }
            // The video is running: take any verse, lyric or overlay off it, so nothing is laid
            // over the bumper. (With stream only, the projector is locked and keeps its words.)
            try? await client.clearWords()
            if atem.state.program[me] != input {
                atem.setPreview(input, me: me)
                try await Task.sleep(nanoseconds: 80_000_000)
                atem.auto(me: me)
            }
            // Stream only: lock the stream on the bumper and free the projector. Only when the
            // stream output's id is right (FreeShow then says the bumper is on it): a lock
            // by a wrong id does nothing, and the projector's slides would land on the stream.
            if s.streamOnly, !changed.locked.isEmpty,
               let path = try? await client.backgroundPath(output: s.streamOutput), FreeShowClient.same(path, b.path) {
                await freeProjector(client)
            }
            phase = .playing
            timeLeft = left
            tell(nil)
            // Fade back just before the end, so the fade finishes as the video does. FreeShow
            // tells the time left of the first unlocked output, which is the projector once
            // it's free: then count down here, and look every second that the stream still
            // plays the bumper (someone may have cleared it).
            let end = Date().addingTimeInterval(left)
            var looked = Date()
            while r == run {
                if projectorFree {
                    left = max(0, end.timeIntervalSinceNow)
                    if Date().timeIntervalSince(looked) >= 1 {
                        looked = Date()
                        // A failed question isn't an answer: only a different (or no) video ends it.
                        var gone = false
                        do {
                            let now = try await client.backgroundPath(output: s.streamOutput)
                            gone = now.map { FreeShowClient.same($0, b.path) } != true
                        } catch {}
                        if gone { break }
                    }
                } else {
                    left = try await client.timeLeft()
                }
                guard r == run else { break }
                timeLeft = left
                if left <= fadeSeconds + 0.2 { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard r == run else { return }
            await fadeBack(client)
        } catch {
            if replaced.contains(r) { tell("Another bumper took over."); return }
            guard r == run else { tell("Stopped before it went on air."); return }
            let why = (error as? FreeShowError)?.description ?? "\(error)"
            problem = why
            if phase == .playing || switching { await fadeBack(client) } else { await putBack(client); reset() }
            tell(why)
        }
    }

    /// Ends the bumper now: fades back to what was Live and clears the video in FreeShow.
    func stop() {
        guard phase == .starting || phase == .playing, let client else { return }
        run += 1
        Task { @MainActor in await self.fadeBack(client) }
    }

    /// Fades back (if the bumper is still what's Live), clears the video and puts FreeShow back.
    @MainActor
    private func fadeBack(_ client: FreeShowClient) async {
        let atem = booth.atem, me = booth.me, input = setup.input
        phase = .ending
        // Only fade if the bumper is still what's Live: someone may have moved on already.
        if atem.state.program[me] == input, let live = returnTo.live, live != input {
            atem.setPreview(live, me: me)
            try? await Task.sleep(nanoseconds: 80_000_000)
            atem.auto(me: me)
            try? await Task.sleep(nanoseconds: UInt64((fadeSeconds + 0.3) * 1_000_000_000))
            if let next = returnTo.next, next != input, atem.state.preview[me] != next { atem.setPreview(next, me: me) }
        }
        // Clear only the stream: the projector is locked again first, so its background stays.
        await takeStreamBack(client)
        try? await client.clearBackground()
        await putBack(client)
        reset()
    }

    /// For a stream-only bumper: lock the other outputs and lift the stream output's style.
    /// Anything done is remembered first, so it's put back even if a later step fails.
    @MainActor
    private func prepare(_ client: FreeShowClient) async throws {
        changed = ([], nil)
        let s = setup
        guard s.streamOnly else { return }
        for id in s.lockOutputs where !id.isEmpty {
            changed.locked.append(id)
            try await client.lock(id, true)
        }
        if !s.streamStyle.isEmpty {
            changed.style = (s.streamOutput, s.streamStyle)
            try await client.setStyle(output: s.streamOutput, style: "")
        }
    }

    /// Locks the stream output on the bumper, then unlocks the projector. In that order, so
    /// the projector's changes never reach the stream; for a moment both are locked, and
    /// nothing is sent then.
    @MainActor
    private func freeProjector(_ client: FreeShowClient) async {
        let s = setup
        guard (try? await client.lock(s.streamOutput, true)) != nil else { return }
        projectorFree = true
        for id in changed.locked { try? await client.lock(id, false) }
    }

    /// Undoes freeProjector: unlocks the stream, then locks the projector again. In that order
    /// so the two are never locked together (FreeShow then sends to every output).
    @MainActor
    private func takeStreamBack(_ client: FreeShowClient) async {
        guard projectorFree else { return }
        projectorFree = false
        try? await client.lock(setup.streamOutput, false)
        for id in changed.locked { try? await client.lock(id, true) }
    }

    /// Puts FreeShow's outputs back as they were before a stream-only bumper.
    @MainActor
    private func putBack(_ client: FreeShowClient) async {
        await takeStreamBack(client)
        let c = changed
        changed = ([], nil)
        if let st = c.style { try? await client.setStyle(output: st.output, style: st.id) }
        for id in c.locked { try? await client.lock(id, false) }
    }

    private func reset() {
        phase = .idle; current = nil; timeLeft = nil
    }
}
