import SwiftUI
import Combine
import CueATEM

/// Offline mode's stand-in pictures: a camera input with no real video (no PTZ picture and no
/// NDI picture coming in) shows a moving pretend camera instead of just its name, so fades,
/// cuts and keys can be tried over a picture. Only in offline mode; real video always wins.
final class PretendCameras: ObservableObject {
    static let shared = PretendCameras()

    /// The inputs showing a pretend camera now.
    @Published private(set) var standIns: Set<Int> = []

    private var timer: Timer?
    /// The real pictures kept running while offline, so one that comes in replaces its stand-in.
    private var held: Set<String> = []
    private var bag = Set<AnyCancellable>()

    private init() {
        Booth.shared.atem.$simulated.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] on in
            on ? self?.start() : self?.stop()
        }.store(in: &bag)
    }

    func shows(_ input: Int?) -> Bool { input.map(standIns.contains) ?? false }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        for n in held { NDIFeedHub.shared.release(n) }
        held = []
        if !standIns.isEmpty { standIns = [] }
    }

    private func refresh() {
        let b = Booth.shared
        guard b.atem.simulated else { return stop() }
        var now = Set<Int>()
        for id in b.atem.state.inputs.keys where (1...999).contains(id) {
            // An NDI picture set for the input (a camera's own stream, or a source's picture).
            let ndi = b.store.ndi(id)
            if let n = ndi, !held.contains(n) { NDIFeedHub.shared.retain(n); held.insert(n) }
            let cam = b.ptz.cameras.first { $0.atemInput == id && !$0.host.isEmpty }
            let camLive = cam.flatMap { CameraPicture.of($0, b.store)?.liveImage } != nil
            let ndiLive = ndi.map { NDIFeedHub.shared.feed($0).live } ?? false
            if !camLive && !ndiLive { now.insert(id) }
        }
        if now != standIns { standIns = now }
    }

    /// PTZ cameras are framed close; other camera inputs wide.
    static func isClose(_ input: Int?) -> Bool {
        guard let input else { return false }
        return Booth.shared.ptz.cameras.contains { $0.atemInput == input }
    }
}

/// An animated pretend camera: a lit stage with someone walking across it. Each input gets
/// its own colors and timing, so two pretend cameras are easy to tell apart.
struct PretendCameraView: View {
    let input: Int
    /// Close framing (a PTZ camera) or wide (a fixed camera).
    var close = false
    var tag = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                draw(&g, size, t)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tag {
                Text("PRETEND CAMERA").font(.sans(9, .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5).frame(height: 15)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.45)))
                    .padding(6)
            }
        }
        .accessibilityLabel("Pretend camera picture")
    }

    private func draw(_ g: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let seed = Double(input) * 1.7
        let hue = (0.62 + Double(input % 5) * 0.07).truncatingRemainder(dividingBy: 1)
        let full = CGRect(origin: .zero, size: s)
        // Back wall: dark, lit from above.
        g.fill(Path(full), with: .linearGradient(Gradient(colors: [Color(hue: hue, saturation: 0.7, brightness: 0.22),
                                                                   Color(hue: hue + 0.05, saturation: 0.6, brightness: 0.5)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))
        // Stage lights: soft beams that sway.
        for i in 0..<4 {
            let x = s.width * (0.15 + 0.23 * Double(i)) + sin(t * 0.5 + Double(i) + seed) * s.width * 0.03
            var beam = Path()
            beam.move(to: CGPoint(x: x - s.width * 0.015, y: 0))
            beam.addLine(to: CGPoint(x: x + s.width * 0.015, y: 0))
            beam.addLine(to: CGPoint(x: x + s.width * 0.09, y: s.height * 0.72))
            beam.addLine(to: CGPoint(x: x - s.width * 0.09, y: s.height * 0.72))
            beam.closeSubpath()
            g.fill(beam, with: .color(Color(hue: hue - 0.1 + 0.06 * Double(i), saturation: 0.35, brightness: 1).opacity(0.13)))
        }
        // The stage floor.
        let floorTop = s.height * (close ? 0.9 : 0.72)
        g.fill(Path(CGRect(x: 0, y: floorTop, width: s.width, height: s.height - floorTop)),
               with: .linearGradient(Gradient(colors: [Color(white: 0.28), Color(white: 0.1)]),
                                     startPoint: CGPoint(x: 0, y: floorTop), endPoint: CGPoint(x: 0, y: s.height)))
        // A person walking slowly across, a little bob in their step.
        let scale = close ? 0.95 : 0.42
        let h = s.height * scale
        let x = s.width * 0.5 + sin(t * 0.35 + seed) * s.width * (close ? 0.18 : 0.3)
        let feet = close ? s.height * 1.15 : floorTop + s.height * 0.02
        let bob = abs(sin(t * 2.2 + seed)) * h * 0.012
        let body = CGRect(x: x - h * 0.13, y: feet - h * 0.78 - bob, width: h * 0.26, height: h * 0.62)
        let head = CGRect(x: x - h * 0.075, y: body.minY - h * 0.17, width: h * 0.15, height: h * 0.17)
        let skin = Color(hue: 0.07, saturation: 0.45, brightness: 0.78)
        g.fill(Path(roundedRect: body, cornerRadius: h * 0.08), with: .color(Color(hue: hue + 0.45, saturation: 0.4, brightness: 0.45)))
        g.fill(Path(ellipseIn: head), with: .color(skin))
        // Soft vignette, like a lens.
        g.fill(Path(full), with: .radialGradient(Gradient(colors: [.clear, Color.black.opacity(0.45)]),
                                                 center: CGPoint(x: s.width / 2, y: s.height / 2),
                                                 startRadius: min(s.width, s.height) * 0.45, endRadius: max(s.width, s.height) * 0.75))
    }
}
