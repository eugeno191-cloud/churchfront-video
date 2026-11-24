import Foundation
import Combine
import CueATEM

/// Keeps an eye on the Zowietek encoder set up in Setup and runs its streaming and recording
/// for the top bar's Stream and Record buttons and Claude's tools. Reads its state every two
/// seconds; reading needs no login, so macOS only asks to open the Keychain when something
/// is started or stopped.
final class ZowietekLink: ObservableObject {
    static let shared = ZowietekLink()

    /// The box as last read. Nil until it first answers.
    @Published private(set) var state: ZowietekState?
    /// Why the last read or command didn't work, if it didn't.
    @Published private(set) var problem: String?
    /// A start or stop is under way.
    @Published private(set) var busy = false

    private(set) var setup = ZowietekSetup()
    private var client: ZowietekClient?
    private var timer: Timer?
    private var reading = false
    /// The login, once read from the Keychain, so it's opened once per run rather than per command.
    private var credential: SavedLogin.Credential?
    private let session: URLSession?
    private let loadLogin: () -> SavedLogin.Credential?

    init(session: URLSession? = nil, login: @escaping () -> SavedLogin.Credential? = { SavedLogin.zowietek.load() }) {
        self.session = session
        self.loadLogin = login
    }

    /// Whether a Zowietek is set up. Then Stream and Record are its, not the switcher's.
    var active: Bool { !setup.host.isEmpty }

    func apply(_ s: ZowietekSetup) {
        guard s != setup else { return }
        let moved = s.host != setup.host
        setup = s
        if moved {
            timer?.invalidate(); timer = nil
            state = nil; problem = nil
            client = s.host.isEmpty ? nil : ZowietekClient(host: s.host, session: session) { [weak self] in self?.login() }
            if client != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
            }
        }
        refresh()
    }

    /// Forget the remembered login, after it's changed in Setup.
    func loginChanged() { credential = nil; refresh() }

    private func login() -> SavedLogin.Credential? {
        if credential == nil { credential = loadLogin() }
        return credential
    }

    // MARK: What the buttons show

    /// The streams the Stream button runs: the ones chosen in Setup, or all of them.
    func chosenStreams(_ st: ZowietekState) -> [ZowietekStream] {
        guard let ids = setup.streams else { return st.streams }
        return st.streams.filter { ids.contains($0.index) }
    }

    /// Where Record records: the one chosen in Setup, else one already recording, else the first with storage in.
    func recorder(_ st: ZowietekState) -> ZowietekRecorder? {
        if let r = setup.recorder, let found = st.recorders.first(where: { $0.index == r }) { return found }
        return st.recorders.first(where: \.recording) ?? st.recorders.first(where: \.mounted)
    }

    enum StreamLook: Equatable { case off, connecting, live, failed }

    var streamLook: StreamLook {
        guard let st = state else { return .off }
        let chosen = chosenStreams(st)
        if chosen.contains(where: \.failed) { return .failed }
        if !chosen.isEmpty, chosen.allSatisfy(\.online) { return .live }
        if chosen.contains(where: \.on) { return .connecting }
        return .off
    }

    var streaming: Bool { streamLook != .off }
    var recording: Bool { state.flatMap { recorder($0) }?.recording ?? false }

    // MARK: Reading and commands

    func refresh(_ then: (() -> Void)? = nil) {
        guard let client, !reading else { then?(); return }
        reading = true
        Task {
            let result: Result<ZowietekState, Error>
            do { result = .success(try await client.state()) } catch { result = .failure(error) }
            await MainActor.run {
                self.reading = false
                guard client === self.client else { then?(); return }  // the address changed meanwhile
                switch result {
                case .success(let st): if st != self.state { self.state = st }; if !self.busy { self.problem = nil }
                case .failure(let e): self.problem = "\(e)"
                }
                then?()
            }
        }
    }

    /// Starts or stops the chosen streams. Calls back on the main thread with nil, or what went wrong.
    func setStreaming(_ on: Bool, done: ((String?) -> Void)? = nil) {
        run(done) { client, st in
            let chosen = self.chosenStreams(st)
            guard !chosen.isEmpty else {
                throw ZowietekError.device(st.streams.isEmpty ? "no streams" : "none chosen")
            }
            for s in chosen where s.on != on { try await client.setStream(s.index, on: on) }
        }
    }

    /// Starts or stops recording on the chosen storage.
    func setRecording(_ on: Bool, done: ((String?) -> Void)? = nil) {
        run(done) { client, st in
            guard let r = self.recorder(st) else { throw ZowietekError.device("100002") }
            try await client.setRecording(r.index, on: on)
        }
    }

    private func run(_ done: ((String?) -> Void)?, _ work: @escaping (ZowietekClient, ZowietekState) async throws -> Void) {
        guard let client else { done?("No Zowietek is set up."); return }
        busy = true
        Task {
            var why: String?
            do {
                // Act on the box as it is now, not as it was at the last read.
                try await work(client, try await client.state())
            } catch let e as ZowietekError {
                why = Self.explain(e)
            } catch {
                why = "\(error)"
            }
            await MainActor.run {
                self.busy = false
                if let why { self.problem = why }
                // A refused login is read again from the Keychain next time, in case it was just fixed.
                if why == ZowietekError.login.description { self.credential = nil }
                self.refresh { done?(why) }
            }
        }
    }

    static func explain(_ e: ZowietekError) -> String {
        if case .device("no streams") = e { return "The Zowietek has no streams saved. Add one on its own web page first." }
        if case .device("none chosen") = e { return "None of the streams chosen in Setup are on the Zowietek any more. Choose them again in Setup." }
        return e.description
    }
}
