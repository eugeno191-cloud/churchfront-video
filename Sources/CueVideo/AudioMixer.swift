import SwiftUI
import CueATEM

/// The Operate page's audio: a fader and mute button for each sound source, and a gain
/// knob for the master level, on the switcher's (classic) audio mixer. It sits between the
/// Next and Live pictures.
///
/// The switcher keeps every level; these controls only send changes, so ATEM Software
/// Control, a panel and this page all stay in step.
struct AudioMixer: View {
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = atem.state
        let channels = AudioChannels.list(store.config.audio, s.audio)
        if !channels.isEmpty || s.audioMaster != nil {
            VStack(alignment: .leading, spacing: T.s2) {
                SectionTitle(title: "Audio")
                HStack(alignment: .top, spacing: T.s2) {
                    ForEach(channels) { c in
                        AudioStrip(input: c.input, name: AudioChannels.name(c, s, store))
                    }
                    if let m = s.audioMaster {
                        Rectangle().fill(T.line).frame(width: 1).padding(.vertical, T.s2)
                        GainKnob(title: "Master", level: m) { atem.setAudioMaster($0) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(T.s2)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Which faders show, and what they're called.
enum AudioChannels {
    /// Sources seen with sound on this run, so muting one doesn't make its fader vanish.
    private static var seen = Set<Int>()

    /// The configured channels, or else: the XLR and RCA inputs, then every input whose
    /// audio is on or follows video (or was, earlier this run).
    static func list(_ configured: [AudioChannel]?, _ audio: [Int: ATEMAudioInput]) -> [AudioChannel] {
        if let configured { return configured }
        for (i, a) in audio where a.mix != 0 { seen.insert(i) }
        let external = audio.filter { $0.value.type == 2 }.keys.sorted()
        let rest = audio.keys.filter { audio[$0]?.type != 2 && seen.contains($0) }.sorted()
        return (external + rest).map { AudioChannel(input: $0) }
    }

    static func name(_ c: AudioChannel, _ s: ATEMState, _ store: ConfigStore) -> String {
        if let l = c.label, !l.isEmpty { return l }
        switch s.audio[c.input]?.port {
        case 32: return "XLR"
        case 64: return "AES"
        case 128: return "RCA"
        default: break
        }
        if (2001...2004).contains(c.input) { return "Media \(c.input - 2000)" }
        return store.label(c.input, s)
    }
}

/// Fader travel to decibels and back: most of the travel is in the useful range around
/// 0 dB, as on a mixing desk. The bottom is silent; the top is +6 dB.
enum FaderTaper {
    private static let span = ATEMAudioLevel.maxDB - ATEMAudioLevel.minDB
    /// 0 (silent) to 1 (+6 dB).
    static func position(_ dB: Double?) -> Double {
        guard let dB else { return 0 }
        let d = min(ATEMAudioLevel.maxDB, max(ATEMAudioLevel.minDB, dB))
        return 1 - ((ATEMAudioLevel.maxDB - d) / span).squareRoot()
    }
    /// Nil at the very bottom: silent.
    static func dB(_ position: Double) -> Double? {
        let p = min(1, max(0, position))
        if p < 0.005 { return nil }
        return ATEMAudioLevel.maxDB - span * (1 - p) * (1 - p)
    }
    static func text(_ dB: Double?) -> String {
        guard let dB else { return "−∞" }
        let r = (dB * 10).rounded() / 10
        return r == 0 ? "0.0" : String(format: "%+.1f", r).replacingOccurrences(of: "-", with: "−")
    }
}

/// Sends a level at most every 40 ms while a control is being dragged, and always the last one.
private final class LevelSender {
    private var last = Date.distantPast
    func send(_ level: Int, final: Bool, _ out: (Int) -> Void) {
        let now = Date()
        guard final || now.timeIntervalSince(last) > 0.04 else { return }
        last = now
        out(level)
    }
}

/// One sound source: its level, a fader, and a mute button.
struct AudioStrip: View {
    let input: Int
    let name: String
    @EnvironmentObject var atem: ATEMClient
    /// The fader while it's held, so the switcher's echo doesn't make it jump.
    @State private var held: Double?
    @State private var start: Double?
    @State private var sender = LevelSender()

    var body: some View {
        let a = atem.state.audio[input]
        let mix = a?.mix ?? 0
        let pos = held ?? FaderTaper.position(a.flatMap { ATEMAudioLevel.dB($0.level) })
        VStack(spacing: 4) {
            Text(FaderTaper.text(FaderTaper.dB(pos)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(mix == 0 ? T.inkSubtle : T.ink)
            GeometryReader { g in
                let h = g.size.height, thumb: CGFloat = 18
                let travel = max(1, h - thumb)
                ZStack(alignment: .top) {
                    // Track, filled up to the fader.
                    Capsule().fill(T.surfaceRaised).frame(width: 6)
                    Capsule().fill(mix == 0 ? T.inkSubtle.opacity(0.5) : T.accent)
                        .frame(width: 6, height: max(0, h - (1 - pos) * travel - thumb / 2))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    // 0 dB mark.
                    Rectangle().fill(T.inkMuted).frame(width: 22, height: 1)
                        .offset(y: (1 - FaderTaper.position(0)) * travel + thumb / 2)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(held == nil ? T.ink : T.accent)
                        .overlay(Rectangle().fill(T.surfaceSunken).frame(height: 2))
                        .frame(width: 34, height: thumb)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(y: (1 - pos) * travel)
                }
                .frame(width: g.size.width, height: h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let s = start ?? pos
                        start = s
                        let p = min(1, max(0, s - Double(v.translation.height / travel)))
                        held = p
                        sender.send(ATEMAudioLevel.level(FaderTaper.dB(p)), final: false) { atem.setAudioLevel(input, $0) }
                    }
                    .onEnded { _ in
                        if let p = held { sender.send(ATEMAudioLevel.level(FaderTaper.dB(p)), final: true) { atem.setAudioLevel(input, $0) } }
                        start = nil
                        // Let the switcher's answer arrive before letting go of the held value.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if start == nil { held = nil } }
                    })
                .onTapGesture(count: 2) { atem.setAudioLevel(input, ATEMAudioLevel.level(0)) }
            }
            .frame(width: 44)
            .frame(minHeight: 80)
            .help("Drag to set \(name)'s level. Double-click for 0 dB.")
            Button {
                atem.setAudioMix(input, mix == 0 ? 1 : 0)
            } label: {
                Text(mix == 0 ? "MUTED" : (mix == 2 ? "AFV" : "ON"))
                    .font(.sans(10, .bold)).tracking(0.5)
                    .foregroundStyle(mix == 0 ? T.onAction : T.ink)
                    .frame(width: 50, height: 22)
                    .background(RoundedRectangle(cornerRadius: T.rSM).fill(mix == 0 ? T.program : T.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(mix == 0 ? Color.clear : T.line))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(mix == 0 ? "Turn \(name) back on" : mix == 2 ? "\(name) is heard only while its picture is Live. Press to mute it." : "Mute \(name)")
            Text(name).font(.sans(11, .semibold)).foregroundStyle(T.inkMuted)
                .lineLimit(1).minimumScaleFactor(0.7).frame(width: 56)
        }
        .frame(width: 56)
    }
}

/// A gain knob: drag up or down to turn it, double-click for 0 dB.
struct GainKnob: View {
    let title: String
    let level: Int
    let set: (Int) -> Void
    @State private var held: Double?
    @State private var start: Double?
    @State private var sender = LevelSender()

    var body: some View {
        let pos = held ?? FaderTaper.position(ATEMAudioLevel.dB(level))
        let angle = -135 + 270 * pos
        VStack(spacing: 6) {
            Text(FaderTaper.text(FaderTaper.dB(pos)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(T.ink)
            ZStack {
                Circle().trim(from: 0, to: 0.75).rotation(.degrees(135))
                    .stroke(T.surfaceRaised, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle().trim(from: 0, to: 0.75 * pos).rotation(.degrees(135))
                    .stroke(T.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle().fill(T.surfaceRaised).padding(9)
                    .overlay(Circle().stroke(T.lineStrong).padding(9))
                Capsule().fill(T.ink).frame(width: 3, height: 13)
                    .offset(y: -14).rotationEffect(.degrees(angle))
            }
            .frame(width: 60, height: 60)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let s = start ?? pos
                    start = s
                    let p = min(1, max(0, s - Double(v.translation.height) / 160))
                    held = p
                    sender.send(ATEMAudioLevel.level(FaderTaper.dB(p)), final: false, set)
                }
                .onEnded { _ in
                    if let p = held { sender.send(ATEMAudioLevel.level(FaderTaper.dB(p)), final: true, set) }
                    start = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if start == nil { held = nil } }
                })
            .onTapGesture(count: 2) { set(ATEMAudioLevel.level(0)) }
            .help("\(title) gain: drag up or down to turn it. Double-click for 0 dB.")
            Text("GAIN").font(.sans(10, .bold)).tracking(0.5).foregroundStyle(T.inkSubtle)
            Text(title).font(.sans(11, .semibold)).foregroundStyle(T.inkMuted)
        }
        .frame(width: 70)
    }
}
