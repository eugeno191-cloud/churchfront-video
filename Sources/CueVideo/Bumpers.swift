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

    func clearBackground() async throws { try await send("clear_background") }

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
final class BumperPlayer: ObservableObject {
    static let shared = BumperPlayer()

    enum Phase: Equatable { case idle, starting, playing, ending }

    @Published private(set) var phase: Phase = .idle
    /// The bumper playing (or starting, or ending).
    @Published private(set) var current: Bumper?
    @Published private(set) var timeLeft: Double?
    @Published var problem: String?

    private let booth: Booth
    private let session: URLSession?
    private let password: () -> String?
    private let setupOverride: (() -> FreeShowSetup)?
    /// Bumped to call off whatever the play loop is doing (Stop, or a new setup).
    private var run = 0
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

    /// Plays a bumper. Calls back on the main thread once it's on air (nil) or with what went wrong.
    func play(_ b: Bumper, started: ((String?) -> Void)? = nil) {
        guard phase == .idle else { started?("A bumper is already playing."); return }
        guard let client else { started?("FreeShow isn't set up. Add its address in Setup."); return }
        let atem = booth.atem, me = booth.me, input = setup.input
        run += 1
        let r = run
        current = b; phase = .starting; timeLeft = nil; problem = nil
        returnTo = (atem.state.program[me], atem.state.preview[me])
        Task { @MainActor in
            // The caller hears exactly once: on air, or why not.
            var told = false
            func tell(_ why: String?) { if !told { told = true; started?(why) } }
            do {
                try await self.prepare(client)
                try await client.play(b.path)
                // Wait for the video to be running before anything goes to air. A long file
                // can take FreeShow several seconds to load (a 5-minute one took about 4).
                var left = 0.0
                for _ in 0..<Int(Self.startWait / 0.2) {
                    left = try await client.timeLeft()
                    if left > 0 || r != self.run { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard r == self.run else {
                    try? await client.clearBackground()
                    await self.putBack(client)
                    tell("Stopped before it went on air."); return
                }
                guard left > 0 else { throw FreeShowError.didNotStart }
                if atem.state.program[me] != input {
                    atem.setPreview(input, me: me)
                    try await Task.sleep(nanoseconds: 80_000_000)
                    atem.auto(me: me)
                }
                self.phase = .playing
                self.timeLeft = left
                tell(nil)
                // Fade back just before the end, so the fade finishes as the video does.
                while r == self.run {
                    left = try await client.timeLeft()
                    self.timeLeft = left
                    if left <= self.fadeSeconds + 0.2 { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                guard r == self.run else { return }
                await self.fadeBack(client)
            } catch {
                guard r == self.run else { await self.putBack(client); tell("Stopped before it went on air."); return }
                let why = (error as? FreeShowError)?.description ?? "\(error)"
                self.problem = why
                if self.phase == .playing { await self.fadeBack(client) } else { await self.putBack(client); self.reset() }
                tell(why)
            }
        }
    }

    /// Ends the bumper now: fades back to what was Live and clears the video in FreeShow.
    func stop() {
        guard phase == .starting || phase == .playing, let client else { return }
        run += 1
        let wasPlaying = phase == .playing
        Task { @MainActor in
            if wasPlaying { await self.fadeBack(client) } else { try? await client.clearBackground(); await self.putBack(client); self.reset() }
        }
    }

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

    /// Puts FreeShow's outputs back as they were before a stream-only bumper.
    @MainActor
    private func putBack(_ client: FreeShowClient) async {
        let c = changed
        changed = ([], nil)
        if let st = c.style { try? await client.setStyle(output: st.output, style: st.id) }
        for id in c.locked { try? await client.lock(id, false) }
    }

    private func reset() {
        phase = .idle; current = nil; timeLeft = nil
    }
}
