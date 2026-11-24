import Foundation
import Security

/// A user name and password kept in this Mac's Keychain (never in the config file).
/// The user name alone is also kept in the app's preferences, so Setup can show it
/// without opening the Keychain. It isn't a secret; the password never leaves the Keychain.
public struct SavedLogin {
    let service: String
    let account: String
    let userKey: String

    /// The Canon cameras' admin login.
    public static let camera = SavedLogin(service: "CueVideo camera admin login", account: "canon", userKey: "cameraLoginUser")
    /// The Zowietek encoder's login, for starting and stopping its streams and recordings.
    public static let zowietek = SavedLogin(service: "CueVideo Zowietek login", account: "zowietek", userKey: "zowietekLoginUser")
    /// FreeShow's API password, if one is set in FreeShow (the user name is unused).
    public static let freeshow = SavedLogin(service: "CueVideo FreeShow API password", account: "freeshow", userKey: "freeshowLoginUser")

    public struct Credential: Equatable { public let user: String; public let password: String
        public init(user: String, password: String) { self.user = user; self.password = password } }

    public func load() -> Credential? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), let nl = s.firstIndex(of: "\n") else { return nil }
        return Credential(user: String(s[..<nl]), password: String(s[s.index(after: nl)...]))
    }

    /// Saves (or replaces) the login. Returns false if the Keychain refused.
    @discardableResult
    public func save(user: String, password: String) -> Bool {
        clear()
        UserDefaults.standard.set(user, forKey: userKey)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                                   kSecValueData as String: Data("\(user)\n\(password)".utf8)]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: userKey)
    }

    /// Whether a login is saved. Asks the Keychain only whether the item is there, not for
    /// what's in it, so macOS never asks for the Mac's password to answer this.
    public var isSaved: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// The saved user name, for showing in Setup (the password is never shown). Read from
    /// the app's preferences, not the Keychain: opening the Keychain item makes macOS ask
    /// for the Mac's password whenever the app has been rebuilt, and Setup redraws often.
    public var savedUser: String? { UserDefaults.standard.string(forKey: userKey) }
}

/// The cameras' admin login. Only needed for changing presets stored on the cameras
/// themselves; everyday control and CueVideo's own shots work without it. One login is
/// used for every Canon camera.
public enum CameraLogin {
    public typealias Credential = SavedLogin.Credential
    public static func load() -> Credential? { SavedLogin.camera.load() }
    @discardableResult
    public static func save(user: String, password: String) -> Bool { SavedLogin.camera.save(user: user, password: password) }
    public static func clear() { SavedLogin.camera.clear() }
    public static var isSaved: Bool { SavedLogin.camera.isSaved }
    public static var savedUser: String? { SavedLogin.camera.savedUser }
}

/// Answers the camera's login challenge (Basic or Digest) once with the saved login.
final class LoginDelegate: NSObject, URLSessionTaskDelegate {
    let credential: URLCredential
    init(_ c: CameraLogin.Credential) { credential = URLCredential(user: c.user, password: c.password, persistence: .forSession) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        if (m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest) && challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else if m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest {
            completionHandler(.cancelAuthenticationChallenge, nil)  // wrong login: stop rather than loop
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
