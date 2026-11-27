import SwiftUI
import AVKit

/// System playback controls and Picture in Picture for live and AirPlay playback.
@available(iOS 17.0, *)
struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsControls: Bool = true
    /// **PiP must be triggered explicitly by the user via the AVPlayerViewController PiP button**
    /// — never on app backgrounding. The auto-on-background behavior was disorienting (audio
    /// would continue with a tiny floating window appearing the moment the user switched apps)
    /// and burned battery. The PiP button itself still works because `allowsPictureInPicturePlayback`
    /// stays on. Default is `false` for `entersPiPAutomatically`.
    var entersPiPAutomatically: Bool = false

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = showsControls
        controller.canStartPictureInPictureAutomaticallyFromInline = entersPiPAutomatically
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = showsControls
        controller.canStartPictureInPictureAutomaticallyFromInline = entersPiPAutomatically
    }
}

/// Displays the shared AVPlayer in the mini-player without adding a second set of AVKit controls.
@available(iOS 17.0, *)
struct InlinePlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.isOpaque = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: VideoView, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class VideoView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

@available(iOS 17.0, *)
struct VLCKitSurface: UIViewRepresentable {
    let activeDrawable: UIView?
    let stagedDrawable: UIView?
    let isCurrentHost: () -> Bool
    let canStartPlayback: () -> Bool

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        container.isCurrentHost = isCurrentHost
        container.canStartPlayback = canStartPlayback
        container.show(active: activeDrawable, staged: stagedDrawable)
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.show(active: nil, staged: nil)
    }

    final class Container: UIView {
        private var drawables: [UIView] = []
        var isCurrentHost: () -> Bool = { false }
        var canStartPlayback: () -> Bool = { false }

        func isReadyForPlayback(_ drawable: UIView) -> Bool {
            window != nil && drawable.superview === self && !bounds.isEmpty
                && drawable.frame == bounds && isCurrentHost() && canStartPlayback()
        }

        func show(active: UIView?, staged: UIView?) {
            let next = [staged, active].compactMap { $0 }
            // A popup transition can move a drawable before SwiftUI tears down its old host.
            for drawable in drawables where drawable.superview === self
                && !next.contains(where: { $0 === drawable }) {
                drawable.removeFromSuperview()
            }
            drawables = next
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard isCurrentHost(), !bounds.isEmpty else { return }
            // Give a newly attached VLC drawable the laid-out viewport size before use.
            for drawable in drawables {
                if drawable.frame != bounds { drawable.frame = bounds }
                if drawable.superview !== self {
                    drawable.backgroundColor = .black
                    addSubview(drawable)
                }
            }
            // Promote a staged drawable in place, keeping its video output attached.
            if let front = drawables.last, subviews.last !== front { bringSubviewToFront(front) }
        }
    }
}

@available(iOS 17.0, *)
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .label
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
