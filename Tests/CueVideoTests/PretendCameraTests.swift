import XCTest
@testable import CueATEM
@testable import CueVideo

/// Key previews without alpha: the background is taken out like the switcher's key does it.
final class KeyRemovalTests: XCTestCase {
    func testGreenGoesAndTheLowerThirdStays() {
        XCTAssertEqual(KeyRemoval.keep(0, 1, 0, "green").3, 0, "pure green is the background")
        XCTAssertEqual(KeyRemoval.keep(0.1, 0.8, 0.1, "green").3, 0, "dimmer green too")
        XCTAssertEqual(KeyRemoval.keep(0.6, 0.2, 0.7, "green").3, 1, "the purple bar stays")
        XCTAssertEqual(KeyRemoval.keep(1, 1, 1, "green").3, 1, "white text stays")
        XCTAssertEqual(KeyRemoval.keep(0.9, 0.7, 0.6, "green").3, 1, "skin tones stay")
    }

    func testGreenSpillIsPulledOffTheEdges() {
        let (_, g, _, a) = KeyRemoval.keep(0.5, 0.7, 0.5, "green")
        XCTAssertGreaterThan(a, 0)
        XCTAssertLessThanOrEqual(g, 0.5, "no green fringe left")
    }

    func testBlueAndBlack() {
        XCTAssertEqual(KeyRemoval.keep(0, 0, 1, "blue").3, 0)
        XCTAssertEqual(KeyRemoval.keep(0, 1, 0, "blue").3, 1, "green stays when blue is removed")
        XCTAssertEqual(KeyRemoval.keep(0, 0, 0, "black").3, 0)
        XCTAssertEqual(KeyRemoval.keep(1, 1, 1, "black").3, 1)
    }

    func testAPictureComesOutTransparentWhereItWasGreen() throws {
        let ctx = CGContext(data: nil, width: 8, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        ctx.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.7, alpha: 1)); ctx.fill(CGRect(x: 4, y: 0, width: 4, height: 2))
        let out = try XCTUnwrap(KeyRemoval.apply(ctx.makeImage()!, "green"))
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        let bpr = out.bytesPerRow
        XCTAssertLessThan(data[0 * 4 + 3], 10, "the green half is see-through")
        XCTAssertGreaterThan(data[bpr * 0 + 6 * 4 + 3], 245, "the purple half is solid")
    }

    func testOlderKeyButtonsStillLoad() throws {
        let k = try JSONDecoder().decode(KeyButton.self, from: Data(#"{"label":"FreeShow","keyer":1}"#.utf8))
        XCTAssertNil(k.remove)
        let g = try JSONDecoder().decode(KeyButton.self, from: Data(#"{"label":"FreeShow","keyer":1,"remove":"green"}"#.utf8))
        XCTAssertEqual(g.remove, "green")
    }
}

/// Offline mode's pretend camera stands in for camera inputs with no real video, and only offline.
final class PretendCameraTests: XCTestCase {
    private func wait(_ s: Double, until: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testCameraInputsWithoutVideoGetAStandInOnlyOffline() {
        let booth = Booth.shared, pretend = PretendCameras.shared
        var c = CueConfig()
        c.sources = [VolunteerSource(input: 1, label: "Wide shot"), VolunteerSource(input: 2, label: "Follow Cam")]
        booth.atem.startOffline(Booth.offlineState(c))
        wait(3) { pretend.shows(1) && pretend.shows(2) }
        XCTAssertTrue(pretend.shows(1))
        XCTAssertTrue(pretend.shows(2))
        XCTAssertFalse(pretend.shows(0), "black isn't a camera")
        XCTAssertFalse(pretend.shows(1000), "nor are color bars")

        booth.atem.connect("")   // leaving offline mode
        wait(2) { !pretend.shows(1) }
        XCTAssertFalse(pretend.shows(1), "never outside offline mode")
    }
}
