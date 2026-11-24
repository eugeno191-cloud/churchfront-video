import XCTest
import CoreGraphics
@testable import CueVideo

/// Each shot keeps one picture, written beside the setup, until it's updated or the shot is deleted.
final class ShotPicturesTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("shot-pictures-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func frame(_ gray: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return ctx.makeImage()!
    }

    func testASavedPictureIsKeptAndReadBack() {
        let shot = UUID()
        let p = ShotPictures(folder: folder)
        XCTAssertNil(p.image(shot))
        XCTAssertTrue(p.save(frame(0.2), shot: shot))
        XCTAssertNotNil(p.image(shot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.url(shot).path))
        // A fresh start (the app reopened) finds it on disk.
        XCTAssertNotNil(ShotPictures(folder: folder).image(shot))
    }

    func testUpdatingReplacesThePicture() throws {
        let shot = UUID()
        let p = ShotPictures(folder: folder)
        p.save(frame(0.1), shot: shot)
        let first = try Data(contentsOf: p.url(shot))
        p.save(frame(0.9), shot: shot)
        let second = try Data(contentsOf: p.url(shot))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(p.revision[shot], 2)
    }

    func testDeletingAShotRemovesItsPicture() {
        let shot = UUID()
        let p = ShotPictures(folder: folder)
        p.save(frame(0.5), shot: shot)
        p.remove(shot)
        XCTAssertNil(p.image(shot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.url(shot).path))
    }

    func testPicturesAreSmall() {
        let p = ShotPictures(folder: folder)
        let shot = UUID()
        p.save(frame(0.5), shot: shot)
        XCTAssertEqual(p.image(shot)?.representations.first?.pixelsWide, ShotPictures.width)
    }
}
