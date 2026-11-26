import XCTest
@testable import CueATEM
@testable import CueVideo

/// A pretend FreeShow REST API (port 5506), inside the test process, with two outputs as at
/// church: Main (the projector, id "default") and Stream (id "stream1"). Like FreeShow, new
/// content goes to the unlocked outputs, one output always stays unlocked, and "time
/// left" and get_output without an id are about the first unlocked one, by name. A played
/// video runs for `length` seconds; a background loop never ends.
final class FakeFreeShow: URLProtocol {
    struct Video { var path: String; var started: Date; var length: Double }
    struct Output { let id: String; let name: String; var locked = false; var background: Video?; var slide = false; var style = "" }

    static var actions: [[String: Any]] = []
    static var auth: [String?] = []
    static var length = 2.5
    static var loadDelay = 0.0
    static var password: String?
    static var outputs: [Output] = []

    static func reset() {
        actions = []; auth = []; length = 2.5; loadDelay = 0; password = nil
        outputs = [Output(id: "default", name: "Main"), Output(id: "stream1", name: "Stream", style: "566104ca88d")]
    }

    static var main: Output { outputs[0] }
    static var stream: Output { outputs[1] }

    /// The outputs new content goes to.
    static var receiving: [Int] {
        let open = outputs.indices.filter { !outputs[$0].locked }
        return open.isEmpty ? Array(outputs.indices) : open
    }

    /// A background video looping on the outputs taking content, as before a service.
    static func loopBackground(_ path: String) {
        for i in receiving { outputs[i].background = Video(path: path, started: Date(), length: .infinity) }
    }

    /// Someone in the booth puts a slide up in FreeShow.
    static func showSlide() { for i in receiving { outputs[i].slide = true } }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeFreeShow.self]
        return URLSession(configuration: c)
    }

    static func did(_ action: String) -> Bool { actions.contains { $0["action"] as? String == action } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); data = d
        }
        let body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let header = request.value(forHTTPHeaderField: "Authorization")
        Self.actions.append(body); Self.auth.append(header)
        var status = 204
        var out = Data()
        func answer(_ value: Any) {
            status = 200
            out = try! JSONSerialization.data(withJSONObject: ["action": body["action"] ?? "", "data": value], options: .fragmentsAllowed)
        }
        if let p = Self.password, header != "Bearer \(p)" {
            status = 401; out = Data(#"{"status":401,"error":"Unauthorized"}"#.utf8)
        } else {
            switch body["action"] as? String {
            case "play_media":
                // FreeShow takes a moment to load the file; until then the old video keeps playing.
                let loops = (body["data"] as? [String: Any])?["loop"] as? Bool ?? true
                let path = body["path"] as? String ?? "", len = loops ? .infinity : Self.length, to = Self.receiving
                let start = { if Self.length > 0 { for i in to { Self.outputs[i].background = Video(path: path, started: Date(), length: len) } } }
                if Self.loadDelay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadDelay, execute: start) } else { start() }
            case "clear_background": for i in Self.receiving { Self.outputs[i].background = nil }
            case "clear_slide": for i in Self.receiving { Self.outputs[i].slide = false }
            case "lock_output":
                // Like FreeShow, a lock that would leave every output locked is turned down.
                if let i = Self.outputs.firstIndex(where: { $0.id == body["outputId"] as? String }) {
                    let lock = body["value"] as? Bool ?? false
                    if !lock || Self.outputs.indices.contains(where: { $0 != i && !Self.outputs[$0].locked }) { Self.outputs[i].locked = lock }
                }
            case "change_output_style":
                let o = body["outputId"] as? String
                if let i = Self.outputs.firstIndex(where: { $0.id == o || $0.name == o }) { Self.outputs[i].style = body["styleId"] as? String ?? "" }
            case "get_playing_video_time_left":
                let first = Self.outputs.first { !$0.locked } ?? Self.outputs[0]
                if let v = first.background {
                    let left = v.length.isInfinite ? 5 : v.length - Date().timeIntervalSince(v.started)
                    if left > 0 { answer(left) }
                }
            case "get_output":
                let o: Output? = (body["id"] as? String).map { id in Self.outputs.first { $0.id == id } } ?? (Self.outputs.first { !$0.locked } ?? Self.outputs[0])
                if let o { answer(["background": o.background.map { ["path": $0.path, "loop": $0.length.isInfinite] as Any } ?? NSNull(), "slide": o.slide ? ["id": "s"] as Any : NSNull() as Any]) } else { answer(NSNull()) }
            case "get_cleared": answer(["background": true])
            default: break
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if !out.isEmpty { client?.urlProtocol(self, didLoad: out) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class BumperTests: XCTestCase {
    let welcome = Bumper(name: "Welcome", path: "C:\\Videos\\welcome.mp4")
    var booth: Booth { Booth.shared }

    override func setUp() {
        FakeFreeShow.reset()
        var c = CueConfig()
        c.sources = [VolunteerSource(input: 1, label: "Wide shot"), VolunteerSource(input: 2, label: "Follow Cam"),
                     VolunteerSource(input: 3, label: "Projection")]
        booth.atem.startOffline(Booth.offlineState(c))   // Live: Wide shot (1), Next: Follow Cam (2), 1 s fades
        wait(3) { self.booth.atem.state.preview[0] == 2 && self.booth.atem.state.program[0] == 1 }
    }

    func player(password: String? = nil, streamOnly: Bool = false) -> BumperPlayer {
        BumperPlayer(booth: booth, session: FakeFreeShow.session, password: { password }) {
            FreeShowSetup(host: "10.0.0.60", input: 3, bumpers: [self.welcome], streamOnly: streamOnly,
                          streamOutput: "stream1", streamStyle: "566104ca88d", lockOutputs: ["default"])
        }
    }

    /// The FreeShow commands sent, in order, leaving out the "time left" and "what's playing" questions.
    var steps: [String] {
        FakeFreeShow.actions.compactMap { a -> String? in
            guard let name = a["action"] as? String, name != "get_playing_video_time_left", name != "get_output" else { return nil }
            switch name {
            case "lock_output": return "lock \(a["outputId"] ?? "") \(a["value"] as? Bool == true ? "on" : "off")"
            case "change_output_style": return "style \(a["outputId"] ?? "") \((a["styleId"] as? String).map { $0.isEmpty ? "none" : $0 } ?? "?")"
            default: return name
            }
        }
    }

    func testStreamOnlyLocksTheProjectorAndPutsEverythingBack() {
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        XCTAssertEqual(started, .some(nil))
        wait(6) { p.phase == .idle }
        XCTAssertEqual(steps, ["lock default on", "style stream1 none", "play_media", "clear_slide", "clear_overlays",
                               "lock default off", "lock stream1 on",          // the projector is free while it plays
                               "lock stream1 off", "lock default on",          // the end: only the stream is cleared
                               "clear_background", "style stream1 566104ca88d", "lock default off"])
        XCTAssertEqual(booth.atem.state.program[0], 1)
    }

    func testStreamOnlyIsPutBackWhenTheVideoNeverStarts() {
        FakeFreeShow.length = 0
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(BumperPlayer.startWait + 3) { started != nil }
        XCTAssertEqual(Array(steps.suffix(2)), ["style stream1 566104ca88d", "lock default off"])
        XCTAssertFalse(steps.contains("clear_slide"), "a bumper that never starts leaves the words alone")
    }

    func testStreamOnlyIsPutBackWhenStoppedEarly() {
        FakeFreeShow.length = 30
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        p.stop()
        wait(4) { p.phase == .idle }
        XCTAssertEqual(Array(steps.suffix(3)), ["clear_background", "style stream1 566104ca88d", "lock default off"])
    }

    func testWithoutStreamOnlyNothingIsLocked() {
        let p = player()
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        wait(6) { p.phase == .idle }
        XCTAssertFalse(steps.contains { $0.hasPrefix("lock") || $0.hasPrefix("style") })
        XCTAssertTrue(steps.contains("clear_slide"), "the words come off the outputs the bumper plays on")
    }

    private func wait(_ seconds: Double, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testABumperFadesToFreeShowAndBackByItself() {
        let p = player()
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        XCTAssertEqual(started, .some(nil))
        let play = FakeFreeShow.actions.first { $0["action"] as? String == "play_media" }
        XCTAssertEqual(play?["path"] as? String, welcome.path)
        XCTAssertEqual((play?["data"] as? [String: Any])?["loop"] as? Bool, false, "a bumper plays once")
        XCTAssertEqual((play?["data"] as? [String: Any])?["muted"] as? Bool, false, "with its sound")
        wait(2) { self.booth.atem.state.program[0] == 3 }
        XCTAssertEqual(booth.atem.state.program[0], 3, "Projection goes Live once the video runs")
        XCTAssertEqual(p.phase, .playing)

        wait(6) { p.phase == .idle }
        XCTAssertEqual(booth.atem.state.program[0], 1, "back to what was Live")
        XCTAssertEqual(booth.atem.state.preview[0], 2, "Next put back as it was")
        XCTAssertTrue(FakeFreeShow.did("clear_background"))
    }

    func testAVideoThatNeverStartsLeavesTheSwitcherAlone() {
        FakeFreeShow.length = 0
        let p = player()
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(BumperPlayer.startWait + 3) { started != nil }
        XCTAssertEqual(started, .some(FreeShowError.didNotStart.description))
        XCTAssertEqual(booth.atem.state.program[0], 1)
        XCTAssertEqual(booth.atem.state.preview[0], 2)
        XCTAssertEqual(p.phase, .idle)
    }

    func testALoopingBackgroundIsNotTakenForTheBumper() {
        // A background loop is playing; the bumper takes 1.5 s to load.
        FakeFreeShow.loopBackground("C:\\Backgrounds\\loop.mp4")
        FakeFreeShow.length = 3
        FakeFreeShow.loadDelay = 1.5
        let p = player()
        let asked = Date()
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(5) { started != nil }
        XCTAssertEqual(started, .some(nil))
        XCTAssertGreaterThan(Date().timeIntervalSince(asked), 1.4, "on air only once the bumper itself is playing")
        XCTAssertEqual(booth.atem.state.program[0], 3)
        wait(6) { p.phase == .idle }
    }

    func testTheProjectorIsFreeWhileAStreamOnlyBumperPlays() {
        FakeFreeShow.loopBackground("C:\\Backgrounds\\loop.mp4")
        FakeFreeShow.length = 3
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        XCTAssertEqual(started, .some(nil))
        XCTAssertTrue(p.projectorFree)
        XCTAssertFalse(FakeFreeShow.main.locked, "slides can change on the projector")
        XCTAssertTrue(FakeFreeShow.stream.locked, "the stream keeps the bumper")
        FakeFreeShow.showSlide()
        XCTAssertTrue(FakeFreeShow.main.slide)
        XCTAssertFalse(FakeFreeShow.stream.slide, "the projector's slide doesn't reach the stream")
        XCTAssertEqual(FakeFreeShow.stream.background?.path, welcome.path)
        // "Time left" now tells the projector's loop; the bumper still ends on time.
        wait(5) { p.phase == .idle }
        XCTAssertEqual(p.phase, .idle)
        XCTAssertEqual(booth.atem.state.program[0], 1)
        XCTAssertNil(FakeFreeShow.stream.background, "the bumper is cleared off the stream")
        XCTAssertEqual(FakeFreeShow.main.background?.path, "C:\\Backgrounds\\loop.mp4", "the projector keeps its background")
        XCTAssertTrue(FakeFreeShow.main.slide, "and its slide")
        XCTAssertFalse(FakeFreeShow.main.locked); XCTAssertFalse(FakeFreeShow.stream.locked)
        XCTAssertEqual(FakeFreeShow.stream.style, "566104ca88d")
    }

    func testFreeShowKeepsOneOutputUnlocked() {
        let c = FreeShowClient(host: "10.0.0.60", port: 5506, session: FakeFreeShow.session) { nil }
        let done = expectation(description: "locks")
        Task {
            try await c.lock("default", true)
            try await c.lock("stream1", true)   // turned down: it would leave nothing unlocked
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(FakeFreeShow.main.locked)
        XCTAssertFalse(FakeFreeShow.stream.locked)
    }

    func testAnotherBumperTakesOverWithNoFade() {
        let splash = Bumper(name: "Splash", path: "C:\\Videos\\splash.mp4")
        FakeFreeShow.loopBackground("C:\\Backgrounds\\loop.mp4")
        FakeFreeShow.length = 30
        let p = player(streamOnly: true)
        var first: String?? = .none, second: String?? = .none
        p.play(welcome) { first = .some($0) }
        wait(3) { first != nil }
        XCTAssertEqual(booth.atem.state.program[0], 3)
        var leftFreeShow = false
        let watch = booth.atem.$state.sink { if $0.program[0] != 3 { leftFreeShow = true } }
        p.play(splash) { second = .some($0) }
        wait(4) { second != nil }
        watch.cancel()
        XCTAssertEqual(second, .some(nil))
        XCTAssertEqual(first, .some(nil), "the first was told once, when it went on air")
        XCTAssertFalse(leftFreeShow, "no fade between bumpers")
        XCTAssertEqual(p.current, splash)
        XCTAssertEqual(p.phase, .playing)
        XCTAssertEqual(FakeFreeShow.stream.background?.path, splash.path)
        XCTAssertEqual(FakeFreeShow.main.background?.path, "C:\\Backgrounds\\loop.mp4", "the projector never got either bumper")
        XCTAssertTrue(p.projectorFree)
        XCTAssertFalse(FakeFreeShow.main.locked)

        p.stop()
        wait(4) { p.phase == .idle }
        XCTAssertEqual(booth.atem.state.program[0], 1, "back to what was Live before the first bumper")
        XCTAssertEqual(booth.atem.state.preview[0], 2)
        XCTAssertNil(FakeFreeShow.stream.background)
        XCTAssertEqual(FakeFreeShow.main.background?.path, "C:\\Backgrounds\\loop.mp4")
        XCTAssertFalse(FakeFreeShow.main.locked); XCTAssertFalse(FakeFreeShow.stream.locked)
    }

    func testALoopingBumperPlaysUntilStopped() {
        let loop = Bumper(name: "Countdown", path: "C:\\Videos\\countdown.mp4", loop: true)
        FakeFreeShow.length = 1   // a short video: once through would be over long before
        for streamOnly in [false, true] {
            FakeFreeShow.reset(); FakeFreeShow.length = 1
            let p = player(streamOnly: streamOnly)
            var started: String?? = .none
            p.play(loop) { started = .some($0) }
            wait(3) { started != nil }
            XCTAssertEqual(started, .some(nil))
            XCTAssertEqual((FakeFreeShow.actions.first { $0["action"] as? String == "play_media" }?["data"] as? [String: Any])?["loop"] as? Bool, true)
            wait(3) { p.phase != .playing }
            XCTAssertEqual(p.phase, .playing, "still playing well past the video's length")
            XCTAssertNil(p.timeLeft, "no countdown for a loop")
            XCTAssertEqual(booth.atem.state.program[0], 3)
            p.stop()
            wait(4) { p.phase == .idle }
            XCTAssertEqual(booth.atem.state.program[0], 1)
            XCTAssertFalse(FakeFreeShow.main.locked); XCTAssertFalse(FakeFreeShow.stream.locked)
            wait(2) { self.booth.atem.state.preview[0] == 2 }
        }
    }

    func testALoopingBumperEndsIfClearedInFreeShow() {
        let loop = Bumper(name: "Countdown", path: "C:\\Videos\\countdown.mp4", loop: true)
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(loop) { started = .some($0) }
        wait(3) { started != nil }
        FakeFreeShow.outputs[1].background = nil   // someone clears it in FreeShow
        wait(4) { p.phase == .idle }
        XCTAssertEqual(p.phase, .idle)
        XCTAssertEqual(booth.atem.state.program[0], 1)
    }

    func testOnlyALoopIsWrittenToTheSetupFile() throws {
        let once = String(data: try JSONEncoder().encode(welcome), encoding: .utf8)!
        XCTAssertFalse(once.contains("loop"))
        let again = try JSONDecoder().decode(Bumper.self, from: JSONEncoder().encode(Bumper(name: "A", path: "/a", loop: true)))
        XCTAssertTrue(again.loop)
    }

    func testPressingThePlayingBumperAgainIsTurnedDown() {
        FakeFreeShow.length = 30
        let p = player()
        var started: String?? = .none, again: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        p.play(welcome) { again = .some($0) }
        XCTAssertEqual(again, .some("Welcome is already playing."))
        p.stop()
        wait(4) { p.phase == .idle }
    }

    func testFreeShowGetsFifteenSecondsToStartAVideo() {
        XCTAssertEqual(BumperPlayer.startWait, 15)
    }

    func testStopEndsItEarly() {
        FakeFreeShow.length = 30
        let p = player()
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        wait(2) { self.booth.atem.state.program[0] == 3 }
        p.stop()
        wait(4) { p.phase == .idle }
        XCTAssertEqual(booth.atem.state.program[0], 1)
        XCTAssertTrue(FakeFreeShow.did("clear_background"))
    }

    func testThePasswordGoesAsABearerToken() async throws {
        FakeFreeShow.password = "pw"
        let ok = FreeShowClient(host: "10.0.0.60", port: 5506, session: FakeFreeShow.session) { "pw" }
        _ = try await ok.send("get_cleared")
        XCTAssertEqual(FakeFreeShow.auth.last, "Bearer pw")
        let wrong = FreeShowClient(host: "10.0.0.60", port: 5506, session: FakeFreeShow.session) { "nope" }
        do { _ = try await wrong.send("get_cleared"); XCTFail("should be turned down") } catch {
            XCTAssertEqual(error as? FreeShowError, .password)
        }
    }

    func testTheWrappedAnswerIsRead() async throws {
        FakeFreeShow.length = 30
        let c = FreeShowClient(host: "10.0.0.60", port: 5506, session: FakeFreeShow.session) { nil }
        try await c.play("/v/w.mp4")
        let left = try await c.timeLeft()
        XCTAssertGreaterThan(left, 25)
    }

    func testNothingPlayingReadsAsZeroLeft() async throws {
        let c = FreeShowClient(host: "10.0.0.60", port: 5506, session: FakeFreeShow.session) { nil }
        let left = try await c.timeLeft()
        XCTAssertEqual(left, 0)
    }

    func testBumpersInTheSetupFileNeedNoIds() throws {
        let json = #"{"freeshow": {"host": "10.0.0.60", "bumpers": [{"name": "Welcome", "path": "/v/w.mp4"}]}}"#
        let a = try JSONDecoder().decode(CueConfig.self, from: Data(json.utf8))
        let b = try JSONDecoder().decode(CueConfig.self, from: Data(json.utf8))
        XCTAssertEqual(a, b, "reading the same file twice gives the same setup")
        XCTAssertEqual(a.freeshow.port, 5506)
        XCTAssertEqual(a.freeshow.input, 3)
    }
}
