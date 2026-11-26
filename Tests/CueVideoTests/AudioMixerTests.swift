import XCTest
@testable import CueATEM
@testable import CueVideo

/// The Operate page's audio faders and master gain knob.
final class AudioMixerTests: XCTestCase {
    func testLevelsMatchTheSwitcher() {
        // Values read off the church switcher.
        XCTAssertEqual(ATEMAudioLevel.dB(32768)!, 0, accuracy: 0.01)
        XCTAssertEqual(ATEMAudioLevel.dB(50752)!, 3.8, accuracy: 0.05)    // master
        XCTAssertEqual(ATEMAudioLevel.dB(10126)!, -10.2, accuracy: 0.05)
        XCTAssertNil(ATEMAudioLevel.dB(0))
        XCTAssertEqual(ATEMAudioLevel.level(0), 32768)
        XCTAssertEqual(ATEMAudioLevel.level(6), 65381)
        XCTAssertEqual(ATEMAudioLevel.level(20), 65381, "never past +6 dB")
        XCTAssertEqual(ATEMAudioLevel.level(nil), 0)
    }

    func testFaderTravel() {
        XCTAssertEqual(FaderTaper.position(nil), 0)
        XCTAssertEqual(FaderTaper.position(6), 1, accuracy: 0.0001)
        XCTAssertNil(FaderTaper.dB(0), "the bottom is silent")
        for d in [-50.0, -20, -6, 0, 3] {
            XCTAssertEqual(FaderTaper.dB(FaderTaper.position(d))!, d, accuracy: 0.001)
        }
        // 0 dB sits about two thirds of the way up, leaving room to fine tune around it.
        XCTAssertEqual(FaderTaper.position(0), 0.7, accuracy: 0.02)
        XCTAssertEqual(FaderTaper.text(0), "0.0")
        XCTAssertEqual(FaderTaper.text(-3.25), "−3.3")
        XCTAssertEqual(FaderTaper.text(nil), "−∞")
    }

    func testDefaultChannelsAreTheOnesInUse() {
        let audio: [Int: ATEMAudioInput] = [
            1: ATEMAudioInput(type: 0, port: 2, mix: 0), 3: ATEMAudioInput(type: 0, port: 1, mix: 1),
            1001: ATEMAudioInput(type: 2, port: 32, mix: 1), 1201: ATEMAudioInput(type: 2, port: 128, mix: 0),
            2002: ATEMAudioInput(type: 1, port: 256, mix: 2),
        ]
        XCTAssertEqual(AudioChannels.list(nil, audio).map(\.input), [1001, 1201, 3, 2002])
        // Muted later, it keeps its fader.
        var muted = audio; muted[3]?.mix = 0
        XCTAssertEqual(AudioChannels.list(nil, muted).map(\.input), [1001, 1201, 3, 2002])
        // A list in the setup wins.
        XCTAssertEqual(AudioChannels.list([AudioChannel(input: 3, label: "Pastor")], audio).map(\.input), [3])
    }

    func testCommandsChangeTheMixer() {
        let atem = ATEMClient()
        var s = ATEMState(); s.audio = [1001: ATEMAudioInput(type: 2, port: 32, mix: 1, level: 32768)]; s.audioMaster = 32768
        atem.startOffline(s)
        settle()
        atem.setAudioLevel(1001, ATEMAudioLevel.level(-6))
        atem.setAudioMix(1001, 0)
        atem.setAudioMaster(ATEMAudioLevel.level(3))
        settle()
        XCTAssertEqual(ATEMAudioLevel.dB(atem.state.audio[1001]!.level)!, -6, accuracy: 0.01)
        XCTAssertEqual(atem.state.audio[1001]?.mix, 0, "muted")
        XCTAssertEqual(ATEMAudioLevel.dB(atem.state.audioMaster!)!, 3, accuracy: 0.01)
        let said = atem.sentLog.map { $0.describe(atem.state) }
        XCTAssertTrue(said.contains("Audio 1001: level -6.0 dB"), "\(said)")
        XCTAssertTrue(said.contains("Audio 1001: off"), "\(said)")
        XCTAssertTrue(said.contains("Audio master: 3.0 dB"), "\(said)")
    }

    private func settle() {
        let e = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { e.fulfill() }
        wait(for: [e], timeout: 2)
    }
}
