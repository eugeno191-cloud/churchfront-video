import SwiftUI
import AppKit
import CueATEM

/// What the whole app shares: the switcher, the cameras and the operator's settings.
final class Booth: ObservableObject {
    /// The volunteer Fade and Cut: change the camera, and leave keys and lower thirds as they
    /// are. If the switcher has a key tied to the next transition (each fade would flip it
    /// on or off), the tie is taken off first. The Full Switcher page still follows ties.
    func fade() { untieKeys(); atem.auto(me: me) }
    func cut() { untieKeys(); atem.cut(me: me) }

    private func untieKeys() {
        let sel = atem.state.nextSelection[me] ?? 1
        if sel != 1 { atem.setNextSelection(1, me: me) }
    }

    static let shared = Booth()
    let atem = ATEMClient()
    let ptz = PTZController(load: ProcessInfo.processInfo.environment["CUEVIDEO_FAKECAMS"] == nil)
    /// The setup, kept in a JSON file people and Claude can edit.
    let store = ConfigStore()
    @Published var simple = UserDefaults.standard.bool(forKey: "simple") { didSet { UserDefaults.standard.set(simple, forKey: "simple") } }
    @Published var followPreview = UserDefaults.standard.object(forKey: "followPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followPreview, forKey: "followPreview") }
    }
    @Published var me = 0
    @Published var showSettings = false
    /// Which view the main window shows. It always opens on Operator. Leaving Operator lets
    /// go of the cameras: the joystick or an arrow key may still be held when the view changes.
    @Published var view: AppView = .operate {
        didSet {
            guard view != oldValue, oldValue == .operate else { return }
            heldArrows.removeAll()
            ptz.stopAllManual()
        }
    }
    /// The page showing in the Engineer view.
    @Published var section: EngineerSection = .scan

    /// Opens a page of the Engineer view.
    func show(_ s: EngineerSection) { section = s; view = .engineer }

    /// The camera on Next, which saved shots, exposure and the Camera menu act on.
    var cameraOnNext: PTZCamera? {
        let next = atem.state.preview[me]
        return ptz.cameras.first { $0.atemInput == next && !$0.host.isEmpty }
    }

    /// The camera the joystick, zoom, focus and arrow keys move: the one on Next, or when
    /// Next isn't a camera, the one on Live, adjusted on air.
    var cameraToFrame: PTZCamera? {
        if let c = cameraOnNext { return c }
        let live = atem.state.program[me]
        return ptz.cameras.first { $0.atemInput == live && !$0.host.isEmpty }
    }

    /// The camera being framed is the one on Live.
    var framingOnAir: Bool { cameraOnNext == nil && cameraToFrame != nil }
    private var heldArrows: Set<UInt16> = []
    /// The title of the volunteer's window (the WindowGroup in CueVideoApp).
    static let mainWindowTitle = "Churchfront Video"

    /// Lets go of any arrow keys being held and stops that camera. Used when the key release
    /// may never reach CueVideo: another window or another app came to the front.
    func releaseArrows() {
        guard !heldArrows.isEmpty else { return }
        heldArrows.removeAll()
        ptz.stopDrive()
    }

    var connectedOnce: Bool { !atem.state.inputs.isEmpty }

    /// Offline mode, for when the switcher can't be reached: the Operate screen runs against a
    /// pretend switcher with the setup's sources, keys and screens, so shots, cameras and the
    /// buttons can be tried. Nothing goes to the switcher. Connecting again ends it.
    func goOffline() {
        atem.startOffline(Self.offlineState(store.config))
    }

    /// Reaches for the real switcher again, leaving offline mode.
    func goOnline() {
        atem.connect(store.config.atemHost)
    }

    static func offlineState(_ c: CueConfig) -> ATEMState {
        var s = ATEMState()
        s.product = "Offline mode"
        // Stream and Record show in the top bar, as they do on a switcher that has them.
        s.hasStreaming = true; s.hasRecording = true
        func add(_ id: Int, _ name: String) { s.inputs[id] = ATEMInput(id: id, long: name, short: String(name.prefix(4)).uppercased()) }
        add(0, "Black")
        add(1000, "Color Bars")
        let ids = c.sources.map(\.input) + c.cameras.compactMap(\.atemInput)
        for src in c.sources { add(src.input, src.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Input \(src.input)") }
        for cam in c.cameras { if let i = cam.atemInput, s.inputs[i] == nil { add(i, cam.name) } }
        let bus = ids.isEmpty ? [0, 1000] : ids
        let mes = max(1, c.me, (c.keys.compactMap(\.me).max() ?? 1))
        for m in 0..<mes {
            s.program[m] = bus[0]
            s.preview[m] = bus.count > 1 ? bus[1] : 0
            s.style[m] = 0; s.nextSelection[m] = 1; s.mixRate[m] = 30
            s.inTransition[m] = false; s.ftbBlack[m] = false
            let keyers = c.keys.filter { ($0.me ?? 1) - 1 == m }.compactMap(\.keyer).max() ?? 1
            s.keyOnAir[m] = Dictionary(uniqueKeysWithValues: (0..<max(1, keyers)).map { ($0, false) })
        }
        let dsks = max(2, c.keys.compactMap(\.dsk).max() ?? 0)
        for d in 0..<dsks { s.dskOnAir[d] = false; s.dskTie[d] = false }
        let auxes = c.screens.flatMap(\.aux).max() ?? 0
        for a in 0..<auxes { s.aux[a] = 10010 }
        if auxes > 0 { add(10010, "Program") }
        return s
    }

    /// Keyboard: 1 to 9 and 0 put that tile of the volunteer's source row on Next, shift
    /// puts it on Live, space cuts, return fades, arrows move the camera on Next.
    ///
    /// These only work in the Operator view, and not while it shows a dialog or a popover:
    /// Space or Return in the Engineer view, or on a "Delete this shot?" question, must never
    /// cut or fade what's live.
    func key(_ e: NSEvent, down: Bool) -> Bool {
        guard view == .operate, let w = NSApp.keyWindow, w.title == Booth.mainWindowTitle, w.attachedSheet == nil else {
            releaseArrows()
            return false
        }
        if let r = w.firstResponder, r is NSTextView { return false }
        if e.modifierFlags.contains(.command) { return false }
        let arrows: [UInt16: (Double, Double)] = [123: (-0.6, 0), 124: (0.6, 0), 125: (0, -0.6), 126: (0, 0.6)]
        if let a = arrows[e.keyCode] {
            // Only the camera being framed moves, as with the joystick: the one on Next, or the
            // one on Live when Next isn't a camera.
            guard let framing = cameraToFrame, framing.id == ptz.selected else {
                heldArrows.removeAll(); ptz.stopDrive(); return true
            }
            if down { heldArrows.insert(e.keyCode) } else { heldArrows.remove(e.keyCode) }
            let x = heldArrows.compactMap { arrows[$0]?.0 }.reduce(0, +)
            let y = heldArrows.compactMap { arrows[$0]?.1 }.reduce(0, +)
            if heldArrows.isEmpty { ptz.stopDrive() } else { ptz.drive(x: x, y: y) }
            _ = a
            return true
        }
        guard down, !e.isARepeat else { return down }
        switch e.keyCode {
        case 49: cut(); return true
        case 36, 76: fade(); return true
        default: break
        }
        // Q W E R T Y U I / A S D F G H J K: the shot deck's tiles, for the camera on Next. [ and ] turn its page.
        if !e.modifierFlags.contains(.option), !e.modifierFlags.contains(.control),
           let cam = cameraOnNext, (atem.state.tally[cam.atemInput ?? -1] ?? 0) & 1 == 0 {
            let deck = ShotDeckState.shared
            if let slot = ShotDeckState.keyCodes[e.keyCode] { deck.press(slot: slot, camera: cam, ptz); return true }
            if e.keyCode == 33 { deck.turn(cam, by: -1, ptz); return true }
            if e.keyCode == 30 { deck.turn(cam, by: 1, ptz); return true }
        }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9]
        if let i = digits[e.keyCode] {
            let src = store.volunteerSources(atem.state)
            guard i < src.count else { return true }
            if e.modifierFlags.contains(.shift) { atem.setProgram(src[i].input, me: me) } else { atem.setPreview(src[i].input, me: me) }
            return true
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        // The Dock keeps an old icon for a rebuilt app at the same path, so set it outright.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        let booth = Booth.shared
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            booth.key(e, down: e.type == .keyDown) ? nil : e
        }
        // An arrow key held while another app or window comes forward never sends its release.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in booth.releaseArrows() }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { n in
            if (n.object as? NSWindow)?.title == Booth.mainWindowTitle { booth.releaseArrows() }
        }
        let env = ProcessInfo.processInfo.environment
        // Self-tests name their own switcher; otherwise the config file says where it is.
        if let host = env["CUEVIDEO_HOST"], !host.isEmpty { booth.atem.connect(host, port: env["CUEVIDEO_PORT"].flatMap(UInt16.init) ?? 9910) }
        if let fake = env["CUEVIDEO_FAKECAMS"] {
            var cams: [PTZCamera] = []
            for (i, name) in ["Center", "Left", "Right"].enumerated() {
                var c = PTZCamera(); c.name = name; c.host = fake; c.port = UInt16(52381 + i); c.atemInput = i + 1
                c.presetNames = [1: "Pulpit", 2: "Wide", 3: "Band"]
                cams.append(c)
            }
            booth.ptz.cameras = cams
        }
        booth.store.attach(booth)
        // A shot's picture is taken when it's saved or updated to now, never when it's recalled.
        booth.ptz.onShotSaved = { [weak booth] cam, shot in
            guard let c = booth?.ptz.cameras.first(where: { $0.id == cam }) else {
                BumperPlayer.write("shot saved for a camera that isn't in the list"); return
            }
            ShotPictures.shared.capture(c, shot: shot)
        }
        AutoTracker.shared.attach()
        // Claude's way in (through the CueVideo MCP server). Not during self-tests, which
        // may run beside the real app.
        if !booth.store.readOnly { ControlServer.shared.start() }
        // For screenshots in self-tests: CUEVIDEO_VIEW=engineer or engineer:routing.
        if let v = env["CUEVIDEO_VIEW"] {
            let parts = v.split(separator: ":").map(String.init)
            if parts.first == "engineer" { booth.show(parts.count > 1 ? EngineerSection(rawValue: parts[1]) ?? .scan : .scan) }
        }
        if let src = env["CUEVIDEO_NDI"] ?? UserDefaults.standard.string(forKey: "ndiSource") {
            NDIMonitor.shared.start(src)
        }
        NDIMonitor.shared.scan()
        if env["CUEVIDEO_FOLLOWTEST"] != nil { SelfTest.followTest() } else if let cams = env["CUEVIDEO_PTZTEST"] { SelfTest.ptzTest(cams) } else if env["CUEVIDEO_REALTEST"] != nil { SelfTest.realTest() } else if env["CUEVIDEO_PROBE"] != nil { SelfTest.probe() } else if env["CUEVIDEO_SELFTEST"] != nil { SelfTest.run() }
    }

    /// Quitting stops every camera CueVideo is moving (auto tracking, the joystick, zoom, a
    /// move Claude started), then waits a moment for the stops to reach the cameras. A Canon
    /// camera keeps turning at the last speed it was given until it's told to stop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AutoTracker.shared.stopAll()
        Booth.shared.ptz.stopAllManual()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CueVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup(Booth.mainWindowTitle) {
            ContentView()
                .booth()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { BoothCommands() }
    }
}

/// The menu bar. View opens each page; Switcher and Camera hold what the Operate page's
/// buttons do, so the keys can be found.
struct BoothCommands: Commands {
    @ObservedObject private var booth = Booth.shared
    @ObservedObject private var store = Booth.shared.store
    @ObservedObject private var cast = StageCast.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { booth.show(.setup) }.keyboardShortcut(",")
        }
        CommandGroup(before: .sidebar) {
            Button("Operate") { booth.view = .operate }.keyboardShortcut("1")
            Button("Stage Scan") { booth.show(.scan) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Routing") { booth.show(.routing) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Full Switcher") { booth.show(.switcher) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Setup") { booth.show(.setup) }
            Button("Status") { booth.show(.status) }
            Divider()
        }
        // Switching and camera commands act only from the Operator view, where the person
        // can see what they're about to change.
        CommandMenu("Switcher") {
            Group {
            Button("Cut (Space)") { booth.cut() }
            Button("Fade (Return)") { booth.fade() }
            Button("Fade to Black") { booth.atem.fadeToBlack(me: booth.me) }
            if !store.config.keys.isEmpty {
                Divider()
                ForEach(store.config.keys) { k in
                    Button("\(k.label) On or Off") { k.toggle(booth.atem) }
                }
            }
            }
            .disabled(booth.view != .operate)
        }
        CommandMenu("Camera") {
            Group {
            Button("Track the Camera on Next") {
                guard let c = booth.cameraOnNext else { return }
                if AutoTracker.shared.isTracking(c.id) { AutoTracker.shared.stop(c.id) } else { AutoTracker.shared.start(c) }
            }
            .keyboardShortcut("t")
            Button("Stop All Tracking") { AutoTracker.shared.stopAll() }.keyboardShortcut(".")
            Menu("Follow by Name") {
                ForEach(cast.names, id: \.self) { n in
                    Button(n) { if let c = booth.cameraOnNext { AutoTracker.shared.start(c, person: n) } }
                }
            }
            .disabled(cast.names.isEmpty)
            Divider()
            Button("Focus the Camera on Next") { if let c = booth.cameraOnNext { booth.ptz.focusOnce(camera: c.id) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            .disabled(booth.view != .operate)
        }
    }
}

extension View {
    /// Everything the app's windows share.
    func booth() -> some View {
        environmentObject(Booth.shared)
            .environmentObject(Booth.shared.atem)
            .environmentObject(Booth.shared.ptz)
            .environmentObject(Booth.shared.store)
            .environmentObject(NDIMonitor.shared)
    }
}
