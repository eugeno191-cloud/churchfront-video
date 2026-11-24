import AppKit
import Combine
import CueATEM

/// A still picture for each saved shot, shown on its tile. Taken from the camera's live
/// picture when the shot is saved, or when it's updated to where the camera is now, and kept
/// until the next update. Recalling a shot never changes its picture.
///
/// Kept as small JPEGs beside the setup file: ~/Library/Application Support/CueVideo/shot-pictures/<shot id>.jpg.
/// Self-tests (any CUEVIDEO_ setting) use a folder of their own, so they never touch these.
final class ShotPictures: ObservableObject {
    static let shared = ShotPictures()

    /// Bumped each time a shot's picture changes, so tiles redraw.
    @Published private(set) var revision: [UUID: Int] = [:]
    /// Shots whose picture is being taken now.
    @Published private(set) var taking: Set<UUID> = []

    let folder: URL
    private var cache: [UUID: NSImage] = [:]
    private var missing: Set<UUID> = []

    static let width = 480

    init(folder: URL? = nil) {
        if let folder {
            self.folder = folder
        } else if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("CUEVIDEO_") }) {
            self.folder = FileManager.default.temporaryDirectory.appendingPathComponent("cuevideo-shot-pictures", isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.folder = support.appendingPathComponent("CueVideo/shot-pictures", isDirectory: true)
        }
    }

    func url(_ shot: UUID) -> URL { folder.appendingPathComponent(shot.uuidString + ".jpg") }

    /// The shot's picture, if it has one.
    func image(_ shot: UUID) -> NSImage? {
        if let i = cache[shot] { return i }
        if missing.contains(shot) { return nil }
        guard let i = NSImage(contentsOf: url(shot)) else { missing.insert(shot); return nil }
        cache[shot] = i
        return i
    }

    /// Keeps `img` as the shot's picture. False if it couldn't be written.
    @discardableResult
    func save(_ img: CGImage, shot: UUID) -> Bool {
        guard let data = Snapshots.jpeg(img, width: Self.width) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url(shot), options: .atomic)
        } catch { return false }
        cache[shot] = NSImage(data: data)
        missing.remove(shot)
        revision[shot, default: 0] += 1
        return true
    }

    func remove(_ shot: UUID) {
        try? FileManager.default.removeItem(at: url(shot))
        cache[shot] = nil
        missing.insert(shot)
        revision[shot, default: 0] += 1
    }

    /// Takes the camera's picture now and keeps it for the shot. Waits up to 4 s for the
    /// picture to start if nothing is showing it. Calls back on the main thread.
    func capture(_ c: PTZCamera, shot: UUID, done: ((Bool) -> Void)? = nil) {
        guard let picture = CameraPicture.of(c) else { done?(false); return }
        taking.insert(shot)
        picture.retain()
        var tries = 0
        func look() {
            if let img = picture.liveImage {
                picture.release()
                taking.remove(shot)
                done?(save(img, shot: shot))
            } else if tries < 40 {
                tries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: look)
            } else {
                picture.release()
                taking.remove(shot)
                done?(false)
            }
        }
        look()
    }
}
