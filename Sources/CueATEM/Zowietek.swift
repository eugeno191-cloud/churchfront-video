import Foundation

// Zowietek encoders (ZowieBox, ZowieCam, ZowiePTZ) over their HTTP API (ZowieTek API v1.5):
// JSON posted to http://<box>/<area>?option=getinfo|setinfo&login_check_flag=1. Changes
// carry the box's login in the body ("user", "psw"); reading the state doesn't need it.

/// One stream destination saved on the box (YouTube, Facebook, a custom RTMP or SRT server).
public struct ZowietekStream: Equatable, Identifiable {
    public var index: Int
    public var name: String
    /// Switched on: the box is pushing (or trying to push) this stream.
    public var on: Bool
    /// The box's push status: 1 online, 2 offline, 3 couldn't connect to the URL.
    public var status: Int
    public var id: Int { index }
    public var online: Bool { on && status == 1 }
    public var failed: Bool { on && status == 3 }
    public init(index: Int, name: String, on: Bool, status: Int) { self.index = index; self.name = name; self.on = on; self.status = status }
}

/// One place the box can record to: USB, the SD card or a NAS.
public struct ZowietekRecorder: Equatable, Identifiable {
    /// The box's id for it, such as "usb1_0", "sdcard_0" or "nas1_0".
    public var index: String
    public var name: String
    /// 0 off, 1 recording, 2 paused.
    public var enable: Int
    /// Whether storage is there to record to (the drive or card is in, the NAS is mounted).
    public var mounted: Bool
    /// Free space in MB, when the box says.
    public var freeMB: Int?
    public var id: String { index }
    public var recording: Bool { enable == 1 || enable == 2 }
    public init(index: String, name: String, enable: Int, mounted: Bool, freeMB: Int?) {
        self.index = index; self.name = name; self.enable = enable; self.mounted = mounted; self.freeMB = freeMB
    }
}

public struct ZowietekState: Equatable {
    public var streams: [ZowietekStream] = []
    public var recorders: [ZowietekRecorder] = []
    public init(streams: [ZowietekStream] = [], recorders: [ZowietekRecorder] = []) { self.streams = streams; self.recorders = recorders }
}

public enum ZowietekError: Error, Equatable, CustomStringConvertible {
    /// The box wants a login, or the saved one is wrong.
    case login
    /// The box answered with an error code.
    case device(String)
    /// The box didn't answer, or answered with something that isn't its API.
    case unreachable(String)

    public var description: String {
        switch self {
        case .login: return "The Zowietek turned down the login. Check the user name and password in Setup."
        case .device(let code): return ZowietekError.meaning[code].map { "The Zowietek said: \($0)." } ?? "The Zowietek answered with error \(code)."
        case .unreachable(let why): return "The Zowietek didn't answer: \(why)"
        }
    }

    static let meaning: [String: String] = [
        "00002": "it isn't ready yet", "00003": "a required setting is missing", "00004": "this model can't do that",
        "00009": "too many commands at once, try again", "00010": "it's restarting", "10001": "there's no video signal",
        "60002": "the stream couldn't start", "60003": "the stream couldn't stop", "60004": "the stream URL isn't valid",
        "60007": "the stream must be stopped first", "60013": "that stream isn't saved on it",
        "80001": "that user doesn't exist", "80004": "that account isn't an admin",
        "100001": "the recording storage is full", "100002": "there's no recording storage",
    ]
}

public final class ZowietekClient {
    /// The box's address, with ":port" if it isn't 80.
    public let host: String
    private let login: () -> SavedLogin.Credential?
    private let session: URLSession

    public init(host: String, session: URLSession? = nil, login: @escaping () -> SavedLogin.Credential?) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.login = login
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 4
            self.session = URLSession(configuration: c)
        }
    }

    /// Streams and recorders, as the box has them now.
    public func state() async throws -> ZowietekState {
        let streams = try await post("stream", "getinfo", ["group": "getStreamStatus"])
        let tasks = try await post("record", "getinfo", ["group": "record", "opt": "get_task_list"])
        return ZowietekState(streams: Self.streams(streams), recorders: Self.recorders(tasks))
    }

    public func setStream(_ index: Int, on: Bool) async throws {
        _ = try await post("stream", "setinfo", ["group": "publish", "opt": "update_publish_switch",
                                                  "data": ["index": index, "switch": on ? 1 : 0]], login: true)
    }

    public func setRecording(_ index: String, on: Bool) async throws {
        _ = try await post("record", "setinfo", ["group": "record", "opt": "set_task_enable",
                                                  "data": ["index": index, "enable": on ? 1 : 0]], login: true)
    }

    // MARK: Requests

    func post(_ area: String, _ option: String, _ body: [String: Any], login withLogin: Bool = false) async throws -> [String: Any] {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/\(area)?option=\(option)&login_check_flag=1") else {
            throw ZowietekError.unreachable("no address set")
        }
        var body = body
        if withLogin {
            guard let l = login() else { throw ZowietekError.login }
            body["user"] = l.user; body["psw"] = l.password
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await session.data(for: req) } catch { throw ZowietekError.unreachable(error.localizedDescription) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZowietekError.unreachable("its answer wasn't the Zowietek API")
        }
        let code = Self.string(json["status"]) ?? ""
        if code == "80003" || code == "80005" { throw ZowietekError.login }
        if !(code.isEmpty || code == "00000" || code == "000000") { throw ZowietekError.device(code) }
        return json
    }

    // MARK: Reading the answers (numbers may come as numbers or as text)

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let i = int(v) { return String(i) }
        return nil
    }

    static func streams(_ json: [String: Any]) -> [ZowietekStream] {
        let list = (json["publish_status"] ?? json["publish"] ?? (json["data"] as? [String: Any])?["publish_status"]) as? [[String: Any]] ?? []
        return list.compactMap { e in
            guard let i = int(e["index"]) else { return nil }
            let name = (e["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (e["desc"] as? String) ?? "Stream \(i)"
            return ZowietekStream(index: i, name: name, on: int(e["switch"]) == 1, status: int(e["status"]) ?? 2)
        }
    }

    static func recorders(_ json: [String: Any]) -> [ZowietekRecorder] {
        let list = json["data"] as? [[String: Any]] ?? []
        return list.compactMap { e in
            guard let i = string(e["index"]) else { return nil }
            let storage = e["storageInfo"] as? [String: Any]
            let name = (storage?["name"] as? String) ?? (e["name"] as? String) ?? i
            return ZowietekRecorder(index: i, name: name, enable: int(e["enable"]) ?? 0,
                                    mounted: int(storage?["status"]) == 1, freeMB: int(storage?["freespace"]))
        }
    }
}
