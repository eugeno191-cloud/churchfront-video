import Foundation
import Combine
import CueATEM

/// The volunteer PREACHING button: one press runs the switcher's "Preaching On" macro, the
/// next runs "Preaching Off". The macros are found by name, so they can sit in any slot.
/// The switcher can't say whether a macro's effect is on, so the app remembers which one
/// ran last, including one run from the Full Switcher page or ATEM Software Control.
enum PreachingMacros {
    /// The slots (0 based) of the On and Off macros, or nil if the switcher lacks either.
    static func find(_ macros: [Int: String]) -> (on: Int, off: Int)? {
        func slot(_ word: String) -> Int? {
            macros.keys.sorted().first { i in
                let words = (macros[i] ?? "").lowercased().split { !$0.isLetter }
                return words.contains("preaching") && words.contains(Substring(word))
            }
        }
        guard let on = slot("on"), let off = slot("off") else { return nil }
        return (on, off)
    }
}

final class Preaching: ObservableObject {
    static let shared = Preaching(atem: Booth.shared.atem)

    let atem: ATEMClient
    private let defaults: UserDefaults
    private var watch: AnyCancellable?

    /// On after Preaching On ran last, off after Preaching Off.
    @Published private(set) var on: Bool { didSet { defaults.set(on, forKey: "preachingOn") } }

    init(atem: ATEMClient, defaults: UserDefaults = .standard) {
        self.atem = atem
        self.defaults = defaults
        on = defaults.bool(forKey: "preachingOn")
        // A macro started anywhere else still moves the button.
        watch = atem.$state.map(\.macroRunning).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] running in
            guard let self, let running, let m = PreachingMacros.find(self.atem.state.macros) else { return }
            if running == m.on { self.on = true } else if running == m.off { self.on = false }
        }
    }

    var macros: (on: Int, off: Int)? { PreachingMacros.find(atem.state.macros) }

    /// Runs Preaching Off if it's on, Preaching On if it's off. False if the macros are missing.
    @discardableResult func toggle() -> Bool {
        guard let m = macros else { return false }
        let turnOn = !on
        atem.runMacro(turnOn ? m.on : m.off)
        on = turnOn
        return true
    }
}
