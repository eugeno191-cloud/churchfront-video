import XCTest
@testable import CueATEM
@testable import CueVideo

/// Offline mode: a pretend switcher inside the app, built from the setup.
final class OfflineModeTests: XCTestCase {
    func config() -> CueConfig {
        var c = CueConfig()
        c.sources = [VolunteerSource(input: 1, label: "Wide shot"), VolunteerSource(input: 2, label: "Follow Cam"),
                     VolunteerSource(input: 3, label: "Projection"), VolunteerSource(input: 3010, label: "Graphics")]
        c.keys = [KeyButton(label: "FreeShow", keyer: 1)]
        c.screens = [ScreenOutput(name: "Livestream", aux: [1])]
        return c
    }

    func testStateComesFromTheSetup() {
        let s = Booth.offlineState(config())
        XCTAssertEqual(s.inputs[2]?.long, "Follow Cam")
        XCTAssertEqual(s.inputs[3010]?.long, "Graphics")
        XCTAssertEqual(s.program[0], 1)
        XCTAssertEqual(s.preview[0], 2)
        XCTAssertEqual(s.keyOnAir[0]?.count, 1)
        XCTAssertEqual(s.auxCount, 1)
    }

    func testStreamAndRecordShowAndToggle() {
        var s = Booth.offlineState(config())
        XCTAssertTrue(s.hasStreaming)
        XCTAssertTrue(s.hasRecording)
        XCTAssertFalse(s.streaming)
        ATEMClient.simulate("StrR", [1, 0, 0, 0], &s)
        ATEMClient.simulate("RcTM", [1, 0, 0, 0], &s)
        XCTAssertTrue(s.streaming)
        XCTAssertTrue(s.recording)
        ATEMClient.simulate("StrR", [0, 0, 0, 0], &s)
        XCTAssertFalse(s.streaming)
    }

    func testCutSwapsLiveAndNext() {
        var s = Booth.offlineState(config())
        ATEMClient.retally(&s)
        ATEMClient.simulate("CPvI", [0, 0, 0, 3], &s)
        XCTAssertEqual(s.preview[0], 3)
        ATEMClient.simulate("DCut", [0, 0, 0, 0], &s)
        XCTAssertEqual(s.program[0], 3)
        XCTAssertEqual(s.preview[0], 1)
        XCTAssertEqual(s.tally[3], 1)
        XCTAssertEqual(s.tally[1], 2)
    }

    func testKeysDSKsAndFadeToBlackToggle() {
        var s = Booth.offlineState(config())
        ATEMClient.simulate("CKOn", [0, 0, 1, 0], &s)
        XCTAssertEqual(s.keyOnAir[0]?[0], true)
        ATEMClient.simulate("DDsA", [0, 0, 0, 0], &s)
        XCTAssertEqual(s.dskOnAir[0], true)
        ATEMClient.simulate("FtbA", [0, 0, 0, 0], &s)
        XCTAssertEqual(s.ftbBlack[0], true)
        ATEMClient.simulate("FtbA", [0, 0, 0, 0], &s)
        XCTAssertEqual(s.ftbBlack[0], false)
    }

    func testAFadeWithTheKeyAsNextTakesTheKeyToo() {
        var s = Booth.offlineState(config())
        ATEMClient.simulate("CTTp", [2, 0, 0, 3], &s)  // background and key 1
        ATEMClient.simulate("DAut", [0, 0, 0, 0], &s)
        XCTAssertEqual(s.program[0], 2)
        XCTAssertEqual(s.keyOnAir[0]?[0], true)
    }
}
