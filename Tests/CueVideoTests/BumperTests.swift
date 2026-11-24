import XCTest
@testable import CueATEM
@testable import CueVideo

/// A pretend FreeShow REST API (port 5506), inside the test process. A played video runs
/// for `length` seconds; "time left" counts down, with FreeShow's empty answer at 0.
final class FakeFreeShow: URLProtocol {
    static var actions: [[String: Any]] = []
    static var auth: [String?] = []
    static var length = 2.5
    static var started: Date?
    static var password: String?

    static func reset() { actions = []; auth = []; length = 2.5; started = nil; password = nil }

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
        if let p = Self.password, header != "Bearer \(p)" {
            status = 401; out = Data(#"{"status":401,"error":"Unauthorized"}"#.utf8)
        } else {
            switch body["action"] as? String {
            case "play_media": Self.started = Self.length > 0 ? Date() : nil
            case "clear_background": Self.started = nil
            case "get_playing_video_time_left":
                if let s = Self.started {
                    let left = Self.length - Date().timeIntervalSince(s)
                    // As FreeShow answers: {"action": ..., "data": value}.
                    if left > 0 { status = 200; out = Data(#"{"action":"get_playing_video_time_left","data":\#(left)}"#.utf8) }
                }
            case "get_cleared": status = 200; out = Data(#"{"action":"get_cleared","data":{"background":true}}"#.utf8)
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
                          streamOutput: "Live Stream", streamStyle: "566104ca88d", lockOutputs: ["default"])
        }
    }

    /// The FreeShow commands sent, in order, leaving out the "time left" questions.
    var steps: [String] {
        FakeFreeShow.actions.compactMap { a -> String? in
            guard let name = a["action"] as? String, name != "get_playing_video_time_left" else { return nil }
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
        XCTAssertEqual(steps, ["lock default on", "style Live Stream none", "play_media",
                               "clear_background", "style Live Stream 566104ca88d", "lock default off"])
        XCTAssertEqual(booth.atem.state.program[0], 1)
    }

    func testStreamOnlyIsPutBackWhenTheVideoNeverStarts() {
        FakeFreeShow.length = 0
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(BumperPlayer.startWait + 3) { started != nil }
        XCTAssertEqual(Array(steps.suffix(2)), ["style Live Stream 566104ca88d", "lock default off"])
    }

    func testStreamOnlyIsPutBackWhenStoppedEarly() {
        FakeFreeShow.length = 30
        let p = player(streamOnly: true)
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        p.stop()
        wait(4) { p.phase == .idle }
        XCTAssertEqual(Array(steps.suffix(3)), ["clear_background", "style Live Stream 566104ca88d", "lock default off"])
    }

    func testWithoutStreamOnlyNothingIsLocked() {
        let p = player()
        var started: String?? = .none
        p.play(welcome) { started = .some($0) }
        wait(3) { started != nil }
        wait(6) { p.phase == .idle }
        XCTAssertFalse(steps.contains { $0.hasPrefix("lock") || $0.hasPrefix("style") })
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
