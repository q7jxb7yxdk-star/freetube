import SwiftUI

/// Shows playback preparation and errors over the video surface.
@available(iOS 17.0, *)
struct PlaybackStatusOverlay: View {
    let state: PlayerStateManager.LoadState

    var body: some View {
        switch state {
        case .resolving:
            overlay(label: "Preparing…")
        case .failed(let message):
            overlay(label: message, error: true)
        case .idle, .readyToPlay:
            EmptyView()
        }
    }

    @ViewBuilder
    private func overlay(label: String, error: Bool = false) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                if error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .transition(.opacity)
    }
}
