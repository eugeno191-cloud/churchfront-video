import XCTest
@testable import CueATEM
@testable import CueVideo

/// The PREACHING button finds the switcher's On and Off macros by name and runs them in turn.
final class PreachingTests: XCTestCase {
    func testFindsTheChurchMacros() {
        let m = PreachingMacros.find([0: "Preaching On", 1: "Preaching Off"])
        XCTAssertEqual(m?.on, 0); XCTAssertEqual(m?.off, 1)
    }

    func testFindsThemInAnySlotAndCase() {
        let m = PreachingMacros.find([2: "Intro", 5: "PREACHING-OFF", 7: "preaching on"])
        XCTAssertEqual(m?.on, 7); XCTAssertEqual(m?.off, 5)
    }

    func testNoButtonWithoutBoth() {
        XCTAssertNil(PreachingMacros.find([0: "Preaching On"]))
        XCTAssertNil(PreachingMacros.find([0: "Online", 1: "Offering"]))
        XCTAssertNil(PreachingMacros.find([:]))
    }

    func testPressesAlternateOnAndOff() {
        let atem = ATEMClient()
        var s = ATEMState(); s.macros = [0: "Preaching On", 1: "Preaching Off"]
        atem.startOffline(s)
        let d = UserDefaults(suiteName: "PreachingTests")!
        d.removePersistentDomain(forName: "PreachingTests")
        let p = Preaching(atem: atem, defaults: d)
        let exp = expectation(description: "offline state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(p.on)
        XCTAssertTrue(p.toggle()); XCTAssertTrue(p.on)
        XCTAssertTrue(p.toggle()); XCTAssertFalse(p.on)
        XCTAssertTrue(Preaching(atem: atem, defaults: d).on == false, "remembered across restarts")
        let sentExp = expectation(description: "log")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sentExp.fulfill() }
        wait(for: [sentExp], timeout: 2)
        let sent = atem.sentLog.map { $0.describe(atem.state) }
        XCTAssertTrue(sent.contains { $0.contains("Run macro 1") }, "\(sent)")
        XCTAssertTrue(sent.contains { $0.contains("Run macro 2") }, "\(sent)")
    }
}
