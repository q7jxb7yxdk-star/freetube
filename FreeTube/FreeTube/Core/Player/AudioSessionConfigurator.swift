import Foundation
import AVFoundation
import OSLog

/// Configures background-capable video playback at app launch.
enum AudioSessionConfigurator {
    private nonisolated static let log = AppLog(subsystem: "com.leshko.freetube", category: "AudioSession")
    private static let activationQueue = DispatchQueue(label: "com.leshko.freetube.audio-session")

    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Set the category before any player item can start and activate the session.
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            log.error("Failed to configure audio session: \(String(describing: error), privacy: .public)")
            return
        }

        if #available(iOS 27.0, *) {
            session.activate(options: []) { activated, error in
                if let error {
                    log.error("Failed to activate audio session: \(String(describing: error), privacy: .public)")
                } else if activated {
                    log.info("Audio session configured for .playback/.moviePlayback")
                } else {
                    log.error("Audio session did not activate")
                }
            }
        } else {
            activationQueue.async {
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                    log.info("Audio session configured for .playback/.moviePlayback")
                } catch {
                    log.error("Failed to activate audio session: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
