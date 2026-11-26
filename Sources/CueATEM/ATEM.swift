import Foundation
import Network
import Combine

// Blackmagic ATEM control over the network (UDP 9910), with no Blackmagic
// software installed. The switcher sends its whole state when we connect and
// every change after, so the state here always matches the panel.

public struct ATEMInput: Identifiable, Hashable {
    public let id: Int
    public var long: String
    public var short: String

    public init(id: Int, long: String, short: String) {
        self.id = id; self.long = long; self.short = short
    }

    /// Sources a program or preview bus can take: black, cameras and other
    /// inputs, bars, colors, media players and SuperSource.
    public var isBusSource: Bool {
        id == 0 || (1...999).contains(id) || id == 1000 || id == 2001 || id == 2002
            || ((3000..<4000).contains(id) && id % 10 == 0) || (6000..<6100).contains(id)
    }
    /// Aux outputs can also take clean feeds and M/E program and preview.
    public var isAuxSource: Bool { isBusSource || (7000..<7100).contains(id) || (10000..<11000).contains(id) }
    public var isExternal: Bool { (1...999).contains(id) }
    /// Inputs first in number order, then black, bars, colors, media players.
    var sortKey: (Int, Int) { isExternal ? (0, id) : (1, id) }
}

/// One input of the classic (non Fairlight) audio mixer.
public struct ATEMAudioInput: Equatable {
    /// 0 video input, 1 media player, 2 external audio (XLR, RCA).
    public var type: Int
    /// 1 SDI, 2 HDMI, 32 XLR, 64 AES/EBU, 128 RCA, 256 internal.
    public var port: Int
    /// 0 off, 1 on, 2 audio follows video.
    public var mix: Int
    /// The fader as the switcher keeps it: 32768 is 0 dB, 65381 is +6 dB, 0 is silent.
    public var level: Int
    public var balance: Int
    public init(type: Int = 0, port: Int = 0, mix: Int = 0, level: Int = 32768, balance: Int = 0) {
        self.type = type; self.port = port; self.mix = mix; self.level = level; self.balance = balance
    }
}

/// Audio levels in decibels and the switcher's own numbers, which run 0 (silent) to 65381 (+6 dB).
public enum ATEMAudioLevel {
    public static let maxDB = 6.0
    public static let minDB = -60.0
    /// Nil for silent.
    public static func dB(_ level: Int) -> Double? {
        let d = 20 * log10(Double(level) / 32768)
        return level <= 0 || d < minDB ? nil : d
    }
    /// Nil gives silent.
    public static func level(_ dB: Double?) -> Int {
        guard let dB, dB >= minDB else { return 0 }
        return min(65381, Int((32768 * pow(10, min(maxDB, dB) / 20)).rounded()))
    }
}

/// Sound levels the switcher reports many times a second, in dBFS (-infinity for silence).
public struct ATEMMeter: Equatable {
    public var left = -Double.infinity, right = -Double.infinity
    public var peakLeft = -Double.infinity, peakRight = -Double.infinity
    public init() {}
    public init(left: Double, right: Double, peakLeft: Double, peakRight: Double) {
        self.left = left; self.right = right; self.peakLeft = peakLeft; self.peakRight = peakRight
    }
}

public struct ATEMAudioMeters: Equatable {
    public var master = ATEMMeter()
    public var inputs: [Int: ATEMMeter] = [:]
    public init() {}

    /// An AMLv report: count, master and monitor levels, the source numbers (padded to a
    /// multiple of 4 bytes), then four levels for each source. Levels are 2^23 at full scale.
    public static func parse(_ d: [UInt8]) -> ATEMAudioMeters? {
        func u16(_ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
        func level(_ i: Int) -> Double {
            let v = Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
            return v == 0 ? -.infinity : 20 * log10(Double(v) / 8_388_608)
        }
        func meter(_ i: Int) -> ATEMMeter { ATEMMeter(left: level(i), right: level(i + 4), peakLeft: level(i + 8), peakRight: level(i + 12)) }
        guard d.count >= 36 else { return nil }
        let n = u16(0)
        let ids = 36, levels = ids + (2 * n + 3) / 4 * 4
        guard d.count >= levels + 16 * n else { return nil }
        var m = ATEMAudioMeters()
        m.master = meter(4)
        for k in 0..<n { m.inputs[u16(ids + 2 * k)] = meter(levels + 16 * k) }
        return m
    }
}

/// The switcher's sound levels, at most 15 times a second.
public final class ATEMLevelFeed: ObservableObject {
    @Published public private(set) var meters = ATEMAudioMeters()
    public init() {}
    public func update(_ m: ATEMAudioMeters) { if meters != m { meters = m } }
}

public struct ATEMState: Equatable {
    public var product = ""
    public var version = ""
    public var inputs: [Int: ATEMInput] = [:]
    public var program: [Int: Int] = [:]
    public var preview: [Int: Int] = [:]
    /// Transition handle, 0 to 1, while a transition is under way.
    public var position: [Int: Double] = [:]
    public var inTransition: [Int: Bool] = [:]
    /// Style of the next transition: 0 mix, 1 dip, 2 wipe, 3 DVE, 4 sting.
    public var style: [Int: Int] = [:]
    /// Next transition: bit 0 background, bit 1 key 1, bit 2 key 2 and so on.
    public var nextSelection: [Int: Int] = [:]
    public var mixRate: [Int: Int] = [:]
    public var keyOnAir: [Int: [Int: Bool]] = [:]
    /// Upstream key sources by M/E then keyer: fill and key (cut) inputs.
    public var keyFill: [Int: [Int: Int]] = [:]
    public var keyCut: [Int: [Int: Int]] = [:]
    /// Downstream key sources by DSK.
    public var dskFill: [Int: Int] = [:]
    public var dskCut: [Int: Int] = [:]
    public var dskOnAir: [Int: Bool] = [:]
    public var dskInTransition: [Int: Bool] = [:]
    public var dskTie: [Int: Bool] = [:]
    public var ftbBlack: [Int: Bool] = [:]
    public var ftbInTransition: [Int: Bool] = [:]
    public var aux: [Int: Int] = [:]
    /// Recorded macros by index (0 based).
    public var macros: [Int: String] = [:]
    public var macroRunning: Int?
    public var streamStatus = 0
    public var recordStatus = 0
    /// Only switchers with a built-in encoder or recorder report these.
    public var hasStreaming = false
    public var hasRecording = false
    /// Tally by source: bit 0 program, bit 1 preview (keys and DSKs included).
    public var tally: [Int: UInt8] = [:]
    /// The classic audio mixer's inputs by audio source number (video inputs by number,
    /// XLR 1001, RCA 1201, media players 2001 and 2002), and the master level.
    public var audio: [Int: ATEMAudioInput] = [:]
    public var audioMaster: Int?

    public init() {}

    public var meCount: Int { max(1, (program.keys.max() ?? 0) + 1) }
    public var keyerCount: Int { keyOnAir[0]?.count ?? 0 }
    public var dskCount: Int { dskOnAir.count }
    public var auxCount: Int { aux.count }
    public var streaming: Bool { streamStatus & 4 != 0 }
    public var streamConnecting: Bool { streamStatus & 2 != 0 }
    public var recording: Bool { recordStatus & 1 != 0 }

    public var busSources: [ATEMInput] { inputs.values.filter(\.isBusSource).sorted { $0.sortKey < $1.sortKey } }
    public var auxSources: [ATEMInput] { inputs.values.filter(\.isAuxSource).sorted { $0.sortKey < $1.sortKey } }
    public func name(_ id: Int?) -> String { id.map { inputs[$0]?.short ?? "\($0)" } ?? "?" }
}

public enum ATEMLink: Equatable {
    case idle
    case connecting
    case online
    case offline(String)
}

public struct ATEMLogEntry: Identifiable {
    public let id = UUID()
    public let time: Date
    /// The four-letter ATEM command, such as CPvI (set preview).
    public let command: String
    public let data: [UInt8]
    /// False when the switcher wasn't connected, so nothing went out.
    public let sent: Bool

    /// A plain description, such as "Preview, M/E 1: input 9".
    public func describe(_ state: ATEMState) -> String {
        func u16(_ i: Int) -> Int { i + 1 < data.count ? Int(data[i]) << 8 | Int(data[i + 1]) : 0 }
        let me = "M/E \(Int(data.first ?? 0) + 1)"
        switch command {
        case "CPgI": return "Program, \(me): \(state.inputs[u16(2)]?.long ?? "input \(u16(2))")"
        case "CPvI": return "Preview, \(me): \(state.inputs[u16(2)]?.long ?? "input \(u16(2))")"
        case "DCut": return "Cut, \(me)"
        case "DAut": return "Auto transition, \(me)"
        case "CTPs": return "T-bar, \(me): \(u16(2) / 100)%"
        case "CTTp": return "Transition settings, M/E \(Int(data.count > 1 ? data[1] : 0) + 1)"
        case "CTMx": return "Mix rate, \(me): \(data.count > 1 ? Int(data[1]) : 0) frames"
        case "CKOn": return "Key \(Int(data.count > 1 ? data[1] : 0) + 1) \(data.count > 2 && data[2] != 0 ? "on" : "off"), \(me)"
        case "CDsL": return "DSK \(Int(data.first ?? 0) + 1) \(data.count > 1 && data[1] != 0 ? "on" : "off")"
        case "CDsT": return "DSK \(Int(data.first ?? 0) + 1) tie \(data.count > 1 && data[1] != 0 ? "on" : "off")"
        case "DDsA": return "DSK \(Int(data.first ?? 0) + 1) auto"
        case "FtbA": return "Fade to black, \(me)"
        case "CAuS": return "Aux \(Int(data.count > 1 ? data[1] : 0) + 1): \(state.inputs[u16(2)]?.long ?? "input \(u16(2))")"
        case "CAMI": return "Audio \(u16(2)): " + (data.first == 1 ? ["off", "on", "follow video"][min(2, Int(data.count > 4 ? data[4] : 0))] : "level \(ATEMAudioLevel.dB(u16(6)).map { String(format: "%.1f dB", $0) } ?? "silent")")
        case "SALN": return "Audio levels \(data.first == 1 ? "on" : "off")"
        case "CAMM": return "Audio master: \(ATEMAudioLevel.dB(u16(2)).map { String(format: "%.1f dB", $0) } ?? "silent")"
        case "MAct": return u16(0) == 0xFFFF ? "Stop macro" : "Run macro \(u16(0) + 1)"
        case "StrR": return "Streaming \(data.first == 1 ? "start" : "stop")"
        case "RcTM": return "Recording \(data.first == 1 ? "start" : "stop")"
        default: return command
        }
    }
}

public final class ATEMClient: ObservableObject {
    @Published public private(set) var state = ATEMState()
    @Published public private(set) var link: ATEMLink = .idle
    @Published public private(set) var host = ""
    /// Which end of the T-bar is at rest, per M/E. Flips when a transition
    /// finishes, as on a hardware panel.
    @Published public private(set) var tbarAtTop: [Int: Bool] = [:]
    /// The last commands this app sent (or tried to send while offline), newest last,
    /// for the Status window.
    @Published public private(set) var sentLog: [ATEMLogEntry] = []
    /// Offline mode: no switcher, so a pretend one inside the app takes the commands and
    /// answers as a switcher would. Nothing goes out on the network.
    @Published public private(set) var simulated = false
    /// Sound levels, in their own object because they change many times a second: only
    /// the meters watch it, so the rest of the page isn't redrawn with every level.
    public let levels = ATEMLevelFeed()
    private var metersSent = 0.0

    private let queue = DispatchQueue(label: "cuevideo.atem")
    private var conn: NWConnection?
    private var target = ""
    private var port: UInt16 = 9910
    private var session: UInt16 = 0x53AB
    private var localID: UInt16 = 0
    private var inFlight: [(id: UInt16, data: Data, sent: Double, tries: Int)] = []
    private var lastInbound = 0.0
    private var lastRemoteID: UInt16?
    private var lastHello = 0.0
    private var connected = false
    private var ready = false
    private var timer: DispatchSourceTimer?
    private var s = ATEMState()
    private var lastPosition: [Int: Double] = [:]

    private enum Flag {
        static let ackRequest: UInt8 = 0x01, newSession: UInt8 = 0x02, retransmit: UInt8 = 0x04
        static let retransmitRequest: UInt8 = 0x08, ackReply: UInt8 = 0x10
    }
    private static let hello: [UInt8] = [0x10, 0x14, 0x53, 0xAB, 0, 0, 0, 0, 0, 0x3A, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0]

    public init() {}

    // MARK: Connection

    public func connect(_ host: String, port: UInt16 = 9910) {
        let h = host.trimmingCharacters(in: .whitespaces)
        self.host = h
        simulated = false
        link = h.isEmpty ? .idle : .connecting
        queue.async {
            self.target = h
            self.port = port
            self.s = ATEMState()
            self.publish()
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
            }
            if !h.isEmpty { self.open() }
        }
    }

    public func disconnect() {
        host = ""
        link = .idle
        queue.async {
            self.target = ""
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel(); self.conn = nil
            self.connected = false; self.ready = false
        }
    }

    /// Offline mode: stops talking to the switcher and runs a pretend one that starts as
    /// `state` (its inputs, keys, DSKs and aux). `host` stays as it was, so the address in
    /// the setup isn't lost, and `connect` ends offline mode.
    public func startOffline(_ state: ATEMState) {
        link = .idle
        simulated = true
        queue.async {
            self.target = ""
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel(); self.conn = nil
            self.connected = false; self.ready = false
            self.inFlight.removeAll()
            self.s = state
            Self.retally(&self.s)
            self.publish()
        }
    }

    /// What a switcher would do with a command, for offline mode. Transitions finish at once.
    static func simulate(_ name: String, _ d: [UInt8], _ s: inout ATEMState) {
        func u16(_ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : 0 }
        let me = Int(d.first ?? 0)
        func take() {
            if (s.nextSelection[me] ?? 1) & 1 != 0, let p = s.preview[me], let q = s.program[me] {
                s.program[me] = p; s.preview[me] = q
            }
            let keys = s.nextSelection[me] ?? 1
            for k in (s.keyOnAir[me] ?? [:]).keys where keys & (2 << k) != 0 { s.keyOnAir[me]?[k]?.toggle() }
            for (k, tied) in s.dskTie where tied { s.dskOnAir[k]?.toggle() }
            s.inTransition[me] = false; s.position[me] = 0
        }
        switch name {
        case "CPgI": s.program[me] = u16(2)
        case "CPvI": s.preview[me] = u16(2)
        case "DCut", "DAut": take()
        case "CTPs": if u16(2) >= 10000 { take() }
        case "CTTp":
            let m = d.count > 1 ? Int(d[1]) : 0
            if d.first == 1, d.count > 2 { s.style[m] = Int(d[2]) }
            if d.first == 2, d.count > 3 { s.nextSelection[m] = Int(d[3]) }
        case "CTMx": if d.count > 1 { s.mixRate[me] = Int(d[1]) }
        case "CAMI" where d.count >= 8:
            var a = s.audio[u16(2)] ?? ATEMAudioInput()
            if d[0] & 1 != 0 { a.mix = Int(d[4]) }
            if d[0] & 2 != 0 { a.level = u16(6) }
            s.audio[u16(2)] = a
        case "CAMM" where d.count >= 4: if d[0] & 1 != 0 { s.audioMaster = u16(2) }
        case "CKOn": if d.count > 2 { s.keyOnAir[me, default: [:]][Int(d[1])] = d[2] != 0 }
        case "CDsL": if d.count > 1 { s.dskOnAir[me] = d[1] != 0 }
        case "CDsT": if d.count > 1 { s.dskTie[me] = d[1] != 0 }
        case "DDsA": s.dskOnAir[me]?.toggle()
        case "FtbA": s.ftbBlack[me] = !(s.ftbBlack[me] ?? false)
        case "CAuS": if d.count > 1 { s.aux[Int(d[1])] = u16(2) }
        case "StrR": s.streamStatus = d.first == 1 ? 4 : 1
        case "RcTM": s.recordStatus = d.first == 1 ? 1 : 0
        default: break
        }
        retally(&s)
    }

    /// Tally from the buses: bit 0 on program, bit 1 on preview.
    static func retally(_ s: inout ATEMState) {
        var t: [Int: UInt8] = [:]
        for (_, i) in s.program { t[i, default: 0] |= 1 }
        for (_, i) in s.preview { t[i, default: 0] |= 2 }
        s.tally = t
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func open() {
        conn?.cancel()
        connected = false
        ready = false
        inFlight.removeAll()
        session = 0x53AB
        localID = 0
        guard !target.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(target), port: p, using: .udp)
        c.start(queue: queue)
        conn = c
        receive(c)
        lastHello = now()
        lastInbound = now()
        c.send(content: Data(Self.hello), completion: .contentProcessed { _ in })
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, c === self.conn else { return }
            if let data, data.count >= 12 { self.handle([UInt8](data)) }
            if err == nil { self.receive(c) }
        }
    }

    private func setLink(_ l: ATEMLink) {
        DispatchQueue.main.async { if self.link != l && !self.target.isEmpty { self.link = l } }
    }

    private func tick() {
        guard !target.isEmpty else { return }
        let t = now()
        if t - lastInbound > 3 {
            if t - lastHello > 1.5 {
                setLink(.offline("No answer from \(target)"))
                open()
            }
            return
        }
        for i in inFlight.indices where t - inFlight[i].sent > 0.06 {
            if inFlight[i].tries >= 10 { setLink(.offline("The switcher stopped answering")); open(); return }
            var d = inFlight[i].data
            d[0] |= Flag.retransmit << 3
            conn?.send(content: d, completion: .contentProcessed { _ in })
            inFlight[i].sent = t
            inFlight[i].tries += 1
        }
    }

    private func handle(_ b: [UInt8]) {
        lastInbound = now()
        let flags = b[0] >> 3
        let length = Int(b[0] & 0x07) << 8 | Int(b[1])
        session = UInt16(b[2]) << 8 | UInt16(b[3])
        let remoteID = UInt16(b[10]) << 8 | UInt16(b[11])

        if flags & Flag.newSession != 0 {
            connected = true
            lastRemoteID = nil
            sendAck(remoteID)
            setLink(.connecting)
            return
        }
        if flags & Flag.ackRequest != 0 {
            sendAck(remoteID)
            // The switcher resends packets it isn't sure we got. Apply each packet once,
            // or an old update can land after a newer one and undo it.
            let fresh = lastRemoteID.map { (Int(remoteID) - Int($0) + 32768) % 32768 } ?? 1
            if fresh > 0 && fresh < 16384 {
                lastRemoteID = remoteID
                if length > 12 && b.count >= length { parse(Array(b[12..<length])) }
            }
        }
        if flags & Flag.ackReply != 0 {
            let acked = UInt16(b[4]) << 8 | UInt16(b[5])
            inFlight.removeAll { p in (Int(acked) - Int(p.id) + 32768) % 32768 < 16384 }
        }
        if flags & Flag.retransmitRequest != 0 {
            for p in inFlight { conn?.send(content: p.data, completion: .contentProcessed { _ in }) }
        }
    }

    private func sendAck(_ id: UInt16) {
        var p = [UInt8](repeating: 0, count: 12)
        p[0] = Flag.ackReply << 3
        p[1] = 12
        p[2] = UInt8(session >> 8); p[3] = UInt8(session & 0xFF)
        p[4] = UInt8(id >> 8); p[5] = UInt8(id & 0xFF)
        conn?.send(content: Data(p), completion: .contentProcessed { _ in })
    }

    // MARK: State from the switcher

    private func u16(_ d: [UInt8], _ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : 0 }
    private func str(_ d: [UInt8], _ r: Range<Int>) -> String {
        guard r.lowerBound < d.count else { return "" }
        let slice = d[r.lowerBound..<min(r.upperBound, d.count)]
        return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func parse(_ payload: [UInt8]) {
        var off = 0
        while off + 8 <= payload.count {
            let len = u16(payload, off)
            guard len >= 8, off + len <= payload.count else { break }
            let name = String(bytes: payload[(off + 4)..<(off + 8)], encoding: .ascii) ?? ""
            apply(name, Array(payload[(off + 8)..<(off + len)]))
            off += len
        }
        if ready { publish() }
    }

    private let trace = ProcessInfo.processInfo.environment["CUEVIDEO_TRACE"].map { Set($0.split(separator: ",").map(String.init)) }

    private func apply(_ name: String, _ d: [UInt8]) {
        if let trace, trace.contains(name) {
            print(String(format: "TRACE %.3f %@ %@", now(), name, d.map { String(format: "%02x", $0) }.joined(separator: " ")))
            fflush(stdout)
        }
        switch name {
        case "InCm":
            ready = true
            setLink(.online)
            // Ask for sound levels; they come only to connections that ask.
            send("SALN", [1, 0, 0, 0])
        case "AMLv":
            let t = now()
            if t - metersSent >= 1.0 / 15, let m = ATEMAudioMeters.parse(d) {
                metersSent = t
                DispatchQueue.main.async { self.levels.update(m) }
            }
        case "_ver" where d.count >= 4: s.version = "\(u16(d, 0)).\(u16(d, 2))"
        case "_pin": s.product = str(d, 0..<44)
        case "InPr" where d.count >= 26:
            let id = u16(d, 0)
            s.inputs[id] = ATEMInput(id: id, long: str(d, 2..<22), short: str(d, 22..<26))
        case "PrgI" where d.count >= 4:
            let me = Int(d[0]), src = u16(d, 2)
            // A finished transition changes program; the switcher doesn't always send a
            // last "not in transition" update after it, so end it here.
            if s.program[me] != src && s.inTransition[me] == true { endTransition(me) }
            s.program[me] = src
        case "PrvI" where d.count >= 4: s.preview[Int(d[0])] = u16(d, 2)
        case "TrPs" where d.count >= 6:
            let me = Int(d[0])
            let was = s.inTransition[me] ?? false
            let isOn = d[1] != 0
            let pos = Double(u16(d, 4)) / 10000
            if was && !isOn { endTransition(me) }
            s.inTransition[me] = isOn
            s.position[me] = pos
            lastPosition[me] = isOn ? pos : 0
        case "TrSS" where d.count >= 5:
            s.style[Int(d[0])] = Int(d[3])
            s.nextSelection[Int(d[0])] = Int(d[4])
        case "TMxP" where d.count >= 2: s.mixRate[Int(d[0])] = Int(d[1])
        case "KeOn" where d.count >= 3: s.keyOnAir[Int(d[0]), default: [:]][Int(d[1])] = d[2] != 0
        case "DskS" where d.count >= 3:
            s.dskOnAir[Int(d[0])] = d[1] != 0
            s.dskInTransition[Int(d[0])] = d[2] != 0
        case "DskP" where d.count >= 2: s.dskTie[Int(d[0])] = d[1] != 0
        case "KeBP" where d.count >= 10:
            s.keyFill[Int(d[0]), default: [:]][Int(d[1])] = u16(d, 6)
            s.keyCut[Int(d[0]), default: [:]][Int(d[1])] = u16(d, 8)
        case "DskB" where d.count >= 6:
            s.dskFill[Int(d[0])] = u16(d, 2)
            s.dskCut[Int(d[0])] = u16(d, 4)
        case "FtbS" where d.count >= 3:
            s.ftbBlack[Int(d[0])] = d[1] != 0
            s.ftbInTransition[Int(d[0])] = d[2] != 0
        case "AuxS" where d.count >= 4: s.aux[Int(d[0])] = u16(d, 2)
        case "MPrp" where d.count >= 8:
            let i = u16(d, 0)
            if d[2] != 0 {
                let n = str(d, 8..<(8 + u16(d, 4)))
                s.macros[i] = n.isEmpty ? "Macro \(i + 1)" : n
            } else {
                s.macros[i] = nil
            }
        case "MRPr" where d.count >= 4: s.macroRunning = d[0] & 1 != 0 ? u16(d, 2) : nil
        case "AMIP" where d.count >= 14:
            let b = u16(d, 12)
            s.audio[u16(d, 0)] = ATEMAudioInput(type: Int(d[2]), port: u16(d, 6), mix: Int(d[8]), level: u16(d, 10),
                                                balance: b >= 0x8000 ? b - 0x10000 : b)
        case "AMMO" where d.count >= 2: s.audioMaster = u16(d, 0)
        case "StRS" where d.count >= 2: s.streamStatus = u16(d, 0); s.hasStreaming = true
        case "RTMS" where d.count >= 2: s.recordStatus = u16(d, 0); s.hasRecording = true
        case "TlSr" where d.count >= 2:
            let n = u16(d, 0)
            var t: [Int: UInt8] = [:]
            for i in 0..<n where 2 + i * 3 + 2 < d.count { t[u16(d, 2 + i * 3)] = d[2 + i * 3 + 2] }
            s.tally = t
        default: break
        }
    }

    /// The T-bar's rest end flips when a transition ran past halfway, as on a hardware panel.
    private func endTransition(_ me: Int) {
        if (lastPosition[me] ?? 0) > 0.5 {
            DispatchQueue.main.async { self.tbarAtTop[me] = !(self.tbarAtTop[me] ?? false) }
        }
        s.inTransition[me] = false
        s.position[me] = 0
        lastPosition[me] = 0
    }

    private func publish() {
        let snap = s
        DispatchQueue.main.async { if self.state != snap { self.state = snap } }
    }

    // MARK: Commands

    private func command(_ name: String, _ data: [UInt8]) -> [UInt8] {
        let len = 8 + data.count
        return [UInt8(len >> 8), UInt8(len & 0xFF), 0, 0] + Array(name.utf8) + data
    }

    private func send(_ name: String, _ data: [UInt8]) {
        queue.async {
            let ok = self.connected && self.ready
            let entry = ATEMLogEntry(time: Date(), command: name, data: data, sent: ok)
            DispatchQueue.main.async {
                self.sentLog.append(entry)
                if self.sentLog.count > 60 { self.sentLog.removeFirst(self.sentLog.count - 60) }
                if self.simulated {
                    self.queue.async { Self.simulate(name, data, &self.s); self.publish() }
                }
            }
            guard ok else { return }
            let commands = self.command(name, data)
            self.localID = (self.localID + 1) % 32768
            let len = 12 + commands.count
            var p = [UInt8](repeating: 0, count: 12)
            p[0] = (Flag.ackRequest << 3) | UInt8((len >> 8) & 0x07)
            p[1] = UInt8(len & 0xFF)
            p[2] = UInt8(self.session >> 8); p[3] = UInt8(self.session & 0xFF)
            p[10] = UInt8(self.localID >> 8); p[11] = UInt8(self.localID & 0xFF)
            let packet = Data(p + commands)
            self.inFlight.append((self.localID, packet, self.now(), 0))
            self.conn?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private func hl(_ v: Int) -> [UInt8] { let c = UInt16(clamping: max(0, v)); return [UInt8(c >> 8), UInt8(c & 0xFF)] }
    private func b(_ v: Int) -> UInt8 { UInt8(clamping: max(0, v)) }

    public func setProgram(_ source: Int, me: Int = 0) { send("CPgI", [b(me), 0] + hl(source)) }
    public func setPreview(_ source: Int, me: Int = 0) { send("CPvI", [b(me), 0] + hl(source)) }
    public func cut(me: Int = 0) { send("DCut", [b(me), 0, 0, 0]) }
    public func auto(me: Int = 0) { send("DAut", [b(me), 0, 0, 0]) }
    /// 0 to 1 from the start of the transition.
    public func setPosition(_ v: Double, me: Int = 0) { send("CTPs", [b(me), 0] + hl(Int((min(1, max(0, v)) * 10000).rounded()))) }
    public func setStyle(_ style: Int, me: Int = 0) { send("CTTp", [1, b(me), b(style), 0]) }
    public func setNextSelection(_ mask: Int, me: Int = 0) { send("CTTp", [2, b(me), 0, b(max(1, mask))]) }
    public func setMixRate(_ frames: Int, me: Int = 0) { send("CTMx", [b(me), b(min(250, max(1, frames))), 0, 0]) }
    public func setKeyOnAir(_ keyer: Int, _ on: Bool, me: Int = 0) { send("CKOn", [b(me), b(keyer), on ? 1 : 0, 0]) }
    public func setDSKOnAir(_ dsk: Int, _ on: Bool) { send("CDsL", [b(dsk), on ? 1 : 0, 0, 0]) }
    public func setDSKTie(_ dsk: Int, _ on: Bool) { send("CDsT", [b(dsk), on ? 1 : 0, 0, 0]) }
    public func dskAuto(_ dsk: Int) { send("DDsA", [b(dsk), 0, 0, 0]) }
    public func fadeToBlack(me: Int = 0) { send("FtbA", [b(me), 0, 0, 0]) }
    public func setAux(_ aux: Int, _ source: Int) { send("CAuS", [1, b(aux)] + hl(source)) }
    public func runMacro(_ index: Int) { send("MAct", hl(index) + [0, 0]) }
    public func stopMacro() { send("MAct", [0xFF, 0xFF, 1, 0]) }
    /// Audio on (1), off (0) or following video (2) for one audio source.
    public func setAudioMix(_ input: Int, _ mix: Int) { send("CAMI", [1, 0] + hl(input) + [b(mix), 0, 0, 0, 0, 0, 0, 0]) }
    /// An input's fader, in the switcher's numbers (see ATEMAudioLevel).
    public func setAudioLevel(_ input: Int, _ level: Int) { send("CAMI", [2, 0] + hl(input) + [0, 0] + hl(level) + [0, 0, 0, 0]) }
    public func setAudioMaster(_ level: Int) { send("CAMM", [1, 0] + hl(level) + [0, 0, 0, 0]) }
    public func setStreaming(_ on: Bool) { send("StrR", [on ? 1 : 0, 0, 0, 0]) }
    public func setRecording(_ on: Bool) { send("RcTM", [on ? 1 : 0, 0, 0, 0]) }
}
