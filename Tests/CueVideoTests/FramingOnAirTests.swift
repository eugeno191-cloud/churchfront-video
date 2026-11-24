import XCTest
@testable import CueATEM
@testable import CueVideo

/// The joystick, zoom and arrow keys frame the camera on Next, or when Next isn't a camera,
/// the camera on Live (on air).
final class FramingOnAirTests: XCTestCase {
    override func tearDown() {
        Booth.shared.ptz.cameras = []
        UserDefaults.standard.removeObject(forKey: "ptzCameras")
    }

    private func wait(until: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testTheLiveCameraIsFramedWhenNextIsNotACamera() {
        let booth = Booth.shared
        var cam = PTZCamera(); cam.name = "Follow Cam"; cam.host = "127.0.0.1"; cam.port = 9; cam.proto = .rawTCP; cam.atemInput = 2
        booth.ptz.cameras = [cam]
        var c = CueConfig()
        c.sources = [VolunteerSource(input: 1, label: "Wide shot"), VolunteerSource(input: 2, label: "Follow Cam")]
        booth.atem.startOffline(Booth.offlineState(c))   // Live: Wide shot (1), Next: Follow Cam (2)
        wait { booth.atem.state.preview[0] == 2 }

        XCTAssertEqual(booth.cameraToFrame?.id, cam.id)
        XCTAssertFalse(booth.framingOnAir, "on Next: framing it is off air")

        booth.atem.cut()                                  // Follow Cam goes Live, Wide shot to Next
        wait { booth.atem.state.program[0] == 2 }
        XCTAssertEqual(booth.cameraToFrame?.id, cam.id, "the Live camera can still be panned and zoomed")
        XCTAssertTrue(booth.framingOnAir)
        XCTAssertNil(booth.cameraOnNext, "saved shots and exposure stay with Next")
    }
}
