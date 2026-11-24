import XCTest
@testable import CueATEM
@testable import CueVideo

/// A pretend Zowietek answering the API v1.5 requests, inside the test process.
final class FakeZowietek: URLProtocol {
    struct Seen { let path: String; let body: [String: Any] }
    static var seen: [Seen] = []
    static var streams: [[String: Any]] = []
    static var tasks: [[String: Any]] = []
    static var password = "secret"

    static func reset() {
        seen = []
        password = "secret"
        streams = [
            ["index": 1, "name": "YouTube", "switch": 0, "status": 2],
            ["index": 2, "name": "Facebook", "switch": 0, "status": 2],
        ]
        tasks = [
            ["index": "usb1_0", "name": "usb1", "enable": 0, "storageInfo": ["name": "USB1", "status": 1, "freespace": 20480]],
            ["index": "sdcard_0", "name": "sdcard", "enable": 0, "storageInfo": ["name": "SD card", "status": 0, "freespace": 0]],
        ]
    }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeZowietek.self]
        return URLSession(configuration: c)
    }

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
        let url = request.url!
        let path = url.path + "?" + (url.query ?? "")
        Self.seen.append(Seen(path: path, body: body))
        var answer: [String: Any] = ["rsp": "succeed", "status": "00000"]
        let setting = url.query?.contains("option=setinfo") == true
        if setting && (body["user"] as? String != "admin" || body["psw"] as? String != Self.password) {
            answer = ["rsp": "failed", "status": "80005"]
        } else if body["group"] as? String == "getStreamStatus" {
            answer["publish_status"] = Self.streams
        } else if body["opt"] as? String == "get_task_list" {
            answer["data"] = Self.tasks
        } else if body["opt"] as? String == "update_publish_switch", let d = body["data"] as? [String: Any],
                  let i = d["index"] as? Int, let j = Self.streams.firstIndex(where: { $0["index"] as? Int == i }) {
            let on = d["switch"] as? Int == 1
            Self.streams[j]["switch"] = on ? 1 : 0
            Self.streams[j]["status"] = on ? 1 : 2
        } else if body["opt"] as? String == "set_task_enable", let d = body["data"] as? [String: Any],
                  let i = d["index"] as? String, let j = Self.tasks.firstIndex(where: { $0["index"] as? String == i }) {
            Self.tasks[j]["enable"] = d["enable"]
        }
        let out = try! JSONSerialization.data(withJSONObject: answer)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: out)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ZowietekTests: XCTestCase {
    let login = SavedLogin.Credential(user: "admin", password: "secret")

    override func setUp() { FakeZowietek.reset() }

    func client(_ login: SavedLogin.Credential? = nil) -> ZowietekClient {
        let l = login ?? self.login
        return ZowietekClient(host: "10.0.0.50", session: FakeZowietek.session) { l }
    }

    func testReadsStreamsAndStorage() async throws {
        let st = try await client().state()
        XCTAssertEqual(st.streams.map(\.name), ["YouTube", "Facebook"])
        XCTAssertEqual(st.recorders.map(\.index), ["usb1_0", "sdcard_0"])
        XCTAssertEqual(st.recorders.first?.mounted, true)
        XCTAssertEqual(st.recorders.last?.mounted, false)
        XCTAssertEqual(st.recorders.first?.freeMB, 20480)
        // Reading sends no login.
        XCTAssertTrue(FakeZowietek.seen.allSatisfy { $0.body["psw"] == nil })
        XCTAssertEqual(FakeZowietek.seen.first?.path, "/stream?option=getinfo&login_check_flag=1")
    }

    func testStartingAStreamSendsTheLoginAndTheDocumentedRequest() async throws {
        try await client().setStream(1, on: true)
        let r = try XCTUnwrap(FakeZowietek.seen.last)
        XCTAssertEqual(r.path, "/stream?option=setinfo&login_check_flag=1")
        XCTAssertEqual(r.body["group"] as? String, "publish")
        XCTAssertEqual(r.body["opt"] as? String, "update_publish_switch")
        XCTAssertEqual((r.body["data"] as? [String: Any])?["switch"] as? Int, 1)
        XCTAssertEqual(r.body["user"] as? String, "admin")
        XCTAssertEqual(r.body["psw"] as? String, "secret")
    }

    func testRecordingUsesTheTaskIndex() async throws {
        try await client().setRecording("usb1_0", on: true)
        let r = try XCTUnwrap(FakeZowietek.seen.last)
        XCTAssertEqual(r.path, "/record?option=setinfo&login_check_flag=1")
        XCTAssertEqual(r.body["opt"] as? String, "set_task_enable")
        XCTAssertEqual((r.body["data"] as? [String: Any])?["index"] as? String, "usb1_0")
        XCTAssertEqual((r.body["data"] as? [String: Any])?["enable"] as? Int, 1)
    }

    func testAWrongPasswordIsALoginError() async {
        do {
            try await client(SavedLogin.Credential(user: "admin", password: "nope")).setStream(1, on: true)
            XCTFail("should have been turned down")
        } catch {
            XCTAssertEqual(error as? ZowietekError, .login)
        }
    }

    func testNoSavedLoginIsALoginError() async {
        let c = ZowietekClient(host: "10.0.0.50", session: FakeZowietek.session) { nil }
        do { try await c.setRecording("usb1_0", on: true); XCTFail("should need a login") } catch {
            XCTAssertEqual(error as? ZowietekError, .login)
        }
    }

    // MARK: What the buttons do

    func link(_ setup: ZowietekSetup) -> ZowietekLink {
        let l = ZowietekLink(session: FakeZowietek.session) { SavedLogin.Credential(user: "admin", password: "secret") }
        l.apply(setup)
        return l
    }

    func wait(_ l: ZowietekLink, until: @escaping (ZowietekLink) -> Bool) {
        let end = Date().addingTimeInterval(3)
        while Date() < end, !until(l) { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testStreamButtonStartsOnlyTheChosenStreams() {
        let l = link(ZowietekSetup(host: "10.0.0.50", streams: [2]))
        wait(l) { $0.state != nil }
        var result: String?? = .none
        l.setStreaming(true) { result = .some($0) }
        wait(l) { _ in result != nil }
        XCTAssertEqual(result, .some(nil))
        XCTAssertEqual(FakeZowietek.streams.map { $0["switch"] as? Int }, [0, 1])
        XCTAssertEqual(l.streamLook, .live)
    }

    func testStreamButtonStartsEveryStreamByDefault() {
        let l = link(ZowietekSetup(host: "10.0.0.50"))
        wait(l) { $0.state != nil }
        var finished = false
        l.setStreaming(true) { _ in finished = true }
        wait(l) { _ in finished }
        XCTAssertEqual(FakeZowietek.streams.map { $0["switch"] as? Int }, [1, 1])
    }

    func testRecordGoesToTheStorageThatIsIn() {
        let l = link(ZowietekSetup(host: "10.0.0.50"))
        wait(l) { $0.state != nil }
        var finished = false
        l.setRecording(true) { _ in finished = true }
        wait(l) { _ in finished }
        XCTAssertEqual(FakeZowietek.tasks.map { $0["enable"] as? Int }, [1, 0])
        XCTAssertTrue(l.recording)
    }

    func testAStreamThatCannotConnectShowsAsFailed() {
        FakeZowietek.streams[0]["switch"] = 1
        FakeZowietek.streams[0]["status"] = 3
        let l = link(ZowietekSetup(host: "10.0.0.50", streams: [1]))
        wait(l) { $0.state != nil }
        XCTAssertEqual(l.streamLook, .failed)
    }

    func testSetupSavesOnlyWhatWasChosen() throws {
        var c = CueConfig()
        c.zowietek = ZowietekSetup(host: "10.0.0.50", streams: nil, recorder: "usb1_0")
        let json = String(data: try JSONEncoder().encode(c.zowietek), encoding: .utf8)!
        XCTAssertFalse(json.contains("streams"))
        let back = try JSONDecoder().decode(CueConfig.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(back.zowietek, c.zowietek)
        // An older setup file without the field still loads.
        XCTAssertEqual(try JSONDecoder().decode(CueConfig.self, from: Data("{}".utf8)).zowietek, ZowietekSetup())
    }
}
