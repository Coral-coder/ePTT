import SwiftUI
import UIKit

/// Covers the whole app the moment it stops being frontmost, so the app-switcher snapshot
/// (which iOS keeps on disk), Slide Over previews and screen mirroring or recording show
/// nothing: no contact names, channels, transmission history or who just keyed up.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(NX.cyan.opacity(0.8))
                Text("NXTPTT")
                    .font(NX.label(18, .bold))
                    .foregroundStyle(NX.textDim)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Whether the screen is being recorded, mirrored or shared right now.
final class ScreenCaptureWatcher: ObservableObject {
    @Published private(set) var isCaptured = false
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.refresh() }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func refresh() {
        isCaptured = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.isCaptured }
            .contains(true)
    }
}
