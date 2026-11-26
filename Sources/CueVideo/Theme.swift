import SwiftUI
import AppKit
import CueDesign

/// Churchfront Signal tokens, from CueKit's CueDesign so CueVideo matches the other Cue apps
/// and picks up changes to the design system with them. `T` is the short name the views use.
enum T {
    static func hex(_ v: UInt32) -> Color { SignalColor.solid(v) }
    static let bg = SignalColor.bg
    static let surface = SignalColor.surface
    static let toolbar = SignalColor.toolbar
    static let header = SignalColor.header
    static let surfaceRaised = SignalColor.surfaceRaised
    static let surfaceSunken = SignalColor.surfaceSunken
    static let line = SignalColor.line
    static let lineStrong = SignalColor.lineStrong
    static let ink = SignalColor.ink
    static let inkMuted = SignalColor.inkMuted
    static let inkSubtle = SignalColor.inkSubtle
    static let accent = SignalColor.accent
    static let accentStrong = SignalColor.accentStrong
    static let accentSoft = SignalColor.accentSoft
    static let onAction = SignalColor.onAction
    static let success = SignalColor.success
    static let successSoft = SignalColor.successSoft
    static let warning = SignalColor.warning
    static let warningSoft = SignalColor.warningSoft
    static let danger = SignalColor.danger
    static let dangerSoft = SignalColor.dangerSoft
    /// Tally: program red, preview green, as on every switcher panel.
    static let program = SignalColor.tallyProgram
    static let preview = SignalColor.tallyPreview

    static let s1 = SignalSpace.s1, s2 = SignalSpace.s2, s3 = SignalSpace.s3, s4 = SignalSpace.s4, s5 = SignalSpace.s5, s6 = SignalSpace.s6
    static let rSM = SignalSpace.rSM, rMD = SignalSpace.rMD, rLG = SignalSpace.rLG
}

enum Fonts {
    static func register() { SignalFont.register() }
}

extension Font {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .signalSans(size, weight) }
}

extension View {
    /// ALL CAPS panel label, tracked out.
    func panelLabel(_ color: Color = T.inkSubtle) -> some View { signalPanelLabel(color) }
}

// The pieces below follow CueScreens (its UI/Style.swift), so the Cue apps read as one family
// in colour and shape: ALL CAPS labels, bordered pill buttons, status words on a wash.

/// Label: bold, ALL CAPS, tracked 0.09em. Buttons and tabs.
struct LabelText: View {
    var text: String
    var size: CGFloat = 12
    init(_ text: String, size: CGFloat = 12) { self.text = text; self.size = size }
    var body: some View {
        Text(text.uppercased()).font(.sans(size, .bold)).tracking(size * 0.09).lineLimit(1)
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(T.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// The secondary button: a caps label in a bordered pill. `active` marks a choice that is
/// on with the accent wash.
struct PillButton: View {
    var title: String
    var icon: String? = nil
    var active = false
    var height: CGFloat = 28
    var fill = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                LabelText(title, size: 11)
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .frame(maxWidth: fill ? .infinity : nil)
            .contentShape(Rectangle())
            .foregroundStyle(active ? T.accent : T.ink)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(active ? T.accentSoft : (hovering ? T.surfaceRaised : .clear)))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(active ? .clear : (hovering ? T.inkSubtle : T.lineStrong), lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A short status word on its own wash.
struct Badge: View {
    enum Tone { case neutral, success, warning, danger }
    var text: String
    var tone: Tone = .neutral
    var dot = false
    var body: some View {
        let (fg, bg): (Color, Color) = {
            switch tone {
            case .neutral: (T.inkMuted, T.surfaceRaised)
            case .success: (T.success, T.successSoft)
            case .warning: (T.warning, T.warningSoft)
            case .danger: (T.danger, T.dangerSoft)
            }
        }()
        HStack(spacing: 5) {
            if dot { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text.uppercased()).font(.sans(10, .bold)).tracking(10 * 0.09)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: T.rSM).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(tone == .neutral ? T.line : .clear))
    }
}

/// A backlit panel button, like the keys on an ATEM control surface.
struct PanelButton: View {
    let title: String
    var subtitle: String? = nil
    var lit: Color? = nil
    var width: CGFloat = 76
    var height: CGFloat = 56
    var titleSize: CGFloat = 14
    var blink = false
    /// A small symbol before the title, such as play.fill for a video.
    var icon: String? = nil
    /// The outline while off, so one kind of button reads apart from another.
    var outline: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                let on = lit != nil && (!blink || Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0)
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        if let icon { Image(systemName: icon).font(.system(size: titleSize - 3, weight: .bold)) }
                        Text(title).font(.sans(titleSize, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if let subtitle { Text(subtitle).font(.sans(9, .medium)).lineLimit(1).opacity(0.8) }
                }
                .padding(.horizontal, 4)
                .frame(width: width, height: height)
                .foregroundStyle(on ? T.onAction : T.inkMuted)
                .background(
                    RoundedRectangle(cornerRadius: T.rMD)
                        .fill(on ? (lit ?? T.surfaceRaised) : T.surfaceRaised)
                        .shadow(color: on ? (lit ?? .clear).opacity(0.55) : .clear, radius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? Color.white.opacity(0.25) : (outline ?? T.line), lineWidth: outline == nil || on ? 1 : 1.5))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
    }
}

/// A section heading on the Operate page: a caps label and a short hint after it.
struct SectionTitle: View {
    let title: String
    var hint: String? = nil
    var color: Color = T.inkSubtle
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: T.s2) {
            Text(title).panelLabel(color)
            if let hint { Text(hint).font(.sans(11)).foregroundStyle(T.inkSubtle).lineLimit(1) }
        }
    }
}

typealias PressStyle = SignalPressStyle
