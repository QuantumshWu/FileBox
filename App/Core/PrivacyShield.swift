import Combine
import SwiftUI
import UIKit

/// An opaque window above everything (full-screen covers included) while the app is inactive or in
/// the background, so the app switcher never shows private content. It only covers: the app stays
/// unlocked underneath and looks the same when it comes back.
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()

    /// Set while a system sheet that makes the app inactive must stay usable (the broadcast picker).
    var isSuppressed = false
    /// Set while a Photos prompt of our own is up: it makes the app inactive, and the shield would
    /// blank the app behind it. Only `.inactive` honours it; the background always gets the shield.
    var suppressWhileInactive = false

    private var window: UIWindow?
    private var playbackObserver: AnyCancellable?

    private init() {
        // A playing video or Picture in Picture keeps the shield away in the background; once that
        // has ended (PiP closed, playback stopped) the shield goes up after all. Read on the next
        // turn, since @Published reports the new value before it is stored.
        playbackObserver = PlaybackState.shared.$keepsViewerInBackground
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard UIApplication.shared.applicationState == .background else { return }
                self?.show()
            }
    }

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
