import SwiftUI
import UIKit

/// An opaque window above everything (full-screen covers included) while the app is inactive or in
/// the background, so the app switcher never shows private content.
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()

    /// Set while a system sheet that makes the app inactive must stay usable (the broadcast picker).
    var isSuppressed = false
    /// Set while a Photos prompt of our own is up: it makes the app inactive, and the shield would
    /// blank the app behind it. Only `.inactive` honours it; the background always gets the shield.
    var suppressWhileInactive = false

    private var window: UIWindow?

    func show() {
        guard window == nil, !isSuppressed, !PlaybackState.shared.keepsViewerInBackground,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let shield = UIWindow(windowScene: scene)
        shield.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        shield.rootViewController = UIHostingController(rootView: ShieldView())
        shield.isHidden = false
        window = shield
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }

    /// Runs `work`, which may show a Photos prompt, with `suppressWhileInactive` set.
    nonisolated static func allowingPrompt<T>(_ work: () async -> T) async -> T {
        await MainActor.run { PrivacyShield.shared.suppressWhileInactive = true }
        let result = await work()
        await MainActor.run { PrivacyShield.shared.suppressWhileInactive = false }
        return result
    }
}

private struct ShieldView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Image(systemName: "folder.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
        }
    }
}
