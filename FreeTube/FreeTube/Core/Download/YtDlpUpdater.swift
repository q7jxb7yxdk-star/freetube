import Foundation
import Observation
import OSLog

/// Checks the official stable yt-dlp channel and stages compatible updates for the next launch.
@available(iOS 17.0, *)
@Observable
@MainActor
final class YtDlpUpdater {
    static let shared = YtDlpUpdater()
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "YtDlpUpdater")
    private let preferences = UserPreferences()
    private(set) var isUpdating = false
    private(set) var lastResult: UpdateResult?

    enum UpdateResult: Equatable {
        case success(version: String)
        case noChange(version: String)
        case failure(message: String)
    }

    private init() {}

    func refreshIfStale() {
        Task { [weak self] in
            guard let self else { return }
            let stale = preferences.lastYtDlpUpdate.map { Date().timeIntervalSince($0) >= Self.ttl } ?? true
            await performUpdate(checkRelease: stale)
        }
    }

    @discardableResult
    func updateNow() async -> UpdateResult {
        await performUpdate(checkRelease: true)
    }

    @discardableResult
    private func performUpdate(checkRelease: Bool) async -> UpdateResult {
        guard !isUpdating else {
            return lastResult ?? .failure(message: "Update already in progress")
        }
        isUpdating = true
        defer { isUpdating = false }

        do {
            let versions = try await PythonRunner.shared.runIsolated { try YtDlpModule.runtimeVersions() }
            preferences.ytDlpVersion = versions.ytDlp
            log.info("Embedded Python \(versions.python, privacy: .public); yt-dlp \(versions.ytDlp, privacy: .public); SSL loaded")
            guard checkRelease else { return .noChange(version: versions.ytDlp) }

            let release = try await YtDlpModule.latestRelease()
            let result: UpdateResult
            if YtDlpModule.isNewer(release.tag_name, than: versions.ytDlp) {
                let data = try await YtDlpModule.download(release)
                try await PythonRunner.shared.runIsolated {
                    try YtDlpModule.stage(data, version: release.tag_name)
                }
                result = .success(version: "\(release.tag_name) (restart required)")
                log.info("Staged yt-dlp \(release.tag_name, privacy: .public) for the next launch")
            } else {
                result = .noChange(version: versions.ytDlp)
            }
            preferences.lastYtDlpUpdate = .now
            lastResult = result
            return result
        } catch {
            let message = error.localizedDescription
            log.error("yt-dlp update failed: \(message, privacy: .public)")
            let result = UpdateResult.failure(message: message)
            lastResult = result
            return result
        }
    }
}
