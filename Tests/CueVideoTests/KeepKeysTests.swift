import XCTest
@testable import CueATEM
@testable import CueVideo

/// Changing cameras with the volunteer Fade and Cut keeps lower thirds on, even when the
/// switcher has the key tied to the next transition.
final class KeepKeysTests: XCTestCase {
    var booth: Booth { Booth.shared }

    override func setUp() {
        var c = CueConfig()
        c.sources = [VolunteerSource(input: 1, label: "Wide shot"), VolunteerSource(input: 2, label: "Follow Cam")]
        booth.atem.startOffline(Booth.offlineState(c))
        wait(3) { self.booth.atem.state.program[0] == 1 }
        booth.atem.setKeyOnAir(0, true, me: 0)
        booth.atem.setNextSelection(0b11, me: 0)   // background and key 1, as the church switcher had it
        wait(2) { self.booth.atem.state.keyOnAir[0]?[0] == true && self.booth.atem.state.nextSelection[0] == 0b11 }
    }

    func testFadeKeepsTheLowerThirds() {
        booth.fade()
        wait(3) { self.booth.atem.state.program[0] == 2 }
        XCTAssertEqual(booth.atem.state.program[0], 2, "the camera changed")
        XCTAssertEqual(booth.atem.state.keyOnAir[0]?[0], true, "the lower thirds stayed on")
        XCTAssertEqual(booth.atem.state.nextSelection[0], 1, "the key is no longer tied")
    }

    func testCutKeepsTheLowerThirds() {
        booth.cut()
        wait(3) { self.booth.atem.state.program[0] == 2 }
        XCTAssertEqual(booth.atem.state.program[0], 2)
        XCTAssertEqual(booth.atem.state.keyOnAir[0]?[0], true)
    }

    func testTheFullSwitcherStillFollowsTies() {
        booth.atem.auto(me: 0)
        wait(3) { self.booth.atem.state.program[0] == 2 }
        XCTAssertEqual(booth.atem.state.keyOnAir[0]?[0], false, "a plain switcher fade takes the tied key")
    }

    private func wait(_ seconds: Double, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
