import CryptoKit
import Foundation

/// Privacy lock. While locked the app shows an empty decoy file manager; typing the passcode into its
/// search field unlocks the real vault. The app locks itself whenever it goes to the background.
/// Only a salted hash of the passcode is stored, on the phone.
@MainActor
final class LockManager: ObservableObject {
    @Published private(set) var isUnlocked = false

    static let defaultPasscode = "pi"
    private let hashKey = "passcodeHash"

    /// Unlocks if `input` is the passcode (case-insensitive, surrounding spaces ignored).
    func tryUnlock(with input: String) -> Bool {
        guard let candidate = Self.normalized(input), Self.hash(candidate) == storedHash else { return false }
        isUnlocked = true
        return true
    }

    func lock() {
        isUnlocked = false
    }

    /// Returns false if the new passcode is empty.
    func changePasscode(to newValue: String) -> Bool {
        guard let clean = Self.normalized(newValue) else { return false }
        UserDefaults.standard.set(Self.hash(clean), forKey: hashKey)
        return true
    }

    private var storedHash: String {
        UserDefaults.standard.string(forKey: hashKey) ?? Self.hash(Self.defaultPasscode)
    }

    private static func normalized(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.isEmpty ? nil : clean
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(("filebox-passcode:" + text).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
