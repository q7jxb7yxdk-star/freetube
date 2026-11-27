import AVFoundation
import CoreMedia
import FFmpegSupport
import Foundation
import Network
import os
import OSLog
import PythonKit
import SwiftData
import UIKit

/// Queues yt-dlp work by priority and executes it on a serial utility queue.
@available(iOS 17.0, *)
actor PythonRunner {
    static let shared = PythonRunner()

    enum Priority {
        case high
        case low
    }

    private typealias Job = @Sendable () -> Void
    private let worker = DispatchQueue(label: "com.leshko.freetube.python", qos: .utility)
    private var highPriority: [Job] = []
    private var lowPriority: [Job] = []
    private var isRunning = false

    private init() {}

    func run(
        argv: [String],
        progress: @escaping @Sendable ([String: PythonObject]) -> Void,
        log: @escaping @Sendable (String, String) -> Void,
        onStart: @escaping @Sendable (ContinuousClock.Instant) -> Void,
        priority: Priority = .low
    ) async throws {
        try await submit(priority: priority, onStart: onStart) {
            try freetube_yt_dlp(argv: argv, progress: progress, log: log)
        }
    }

    /// Run a synchronous Python operation. Only Swift values may leave the interpreter.
    func runIsolated<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await submit(priority: .high, work)
    }

    private func submit<T: Sendable>(
        priority: Priority,
        onStart: (@Sendable (ContinuousClock.Instant) -> Void)? = nil,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let queuedAt = ContinuousClock.now
            let job: Job = {
                onStart?(queuedAt)
                do {
                    let moduleURL = try YtDlpModule.activeArchive()
                    let result = try EmbeddedPython.withInterpreter(moduleURL: moduleURL) {
                        do {
                            return try work()
                        } catch let error as YtDlpDownloadError {
                            throw error
                        } catch {
                            // PythonKit errors may own Python objects. Format and release
                            // them before the interpreter lock is released.
                            throw PythonJobError(message: String(describing: error))
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            switch priority {
            case .high: highPriority.append(job)
            case .low: lowPriority.append(job)
            }
            guard !isRunning else { return }
            isRunning = true
            Task { await drain() }
        }
    }

    private func drain() async {
        while !highPriority.isEmpty || !lowPriority.isEmpty {
            let job = highPriority.isEmpty ? lowPriority.removeFirst() : highPriority.removeFirst()
            await withCheckedContinuation { continuation in
                worker.async {
                    job()
                    continuation.resume(returning: ())
                }
            }
        }
        isRunning = false
    }

    private nonisolated struct PythonJobError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Serializes every call into the ffmpeg C library.
///
/// **Why this is necessary:** `FFmpegSupport.ffmpeg(_:)` is a re-entrant entry point into a C
/// library with shared global state — most painfully the `+faststart` post-pass (which calls
/// `ff_format_shift_data` to move the moov atom to the front of the file). That pass walks
/// global I/O buffers and is *not* thread-safe; two concurrent invocations on the cooperative
/// thread pool race on `_platform_memmove` and crash with EXC_BAD_ACCESS. The `Hook.m` shim also
/// uses `setjmp`/`longjmp`, which has undefined behavior across concurrent calls.
///
/// Parallel playlist downloads (Download All firing N `ensureDownloaded` tasks at once) was the
/// trigger that exposed this — each yt-dlp completion fed into its own `Task.detached` ffmpeg
/// call. With this actor, every ffmpeg invocation chains strictly behind the previous one
/// through `pending`, same FIFO pattern `PythonRunner` uses for yt-dlp.
@available(iOS 17.0, *)
actor FFmpegRunner {
    static let shared = FFmpegRunner()

    /// Tail of the in-flight FIFO. New callers await this before invoking ffmpeg, so only one
    /// ffmpeg call is ever in flight at a time even though the actor body itself can suspend.
    private var pending: Task<Void, Never>?

    private init() {}

    /// Runs ffmpeg with the given argv off the main actor and returns its exit code. Concurrent
    /// callers are queued — they don't run until the previous ffmpeg call has fully returned.
    func run(_ args: [String]) async -> Int32 {
        let previous = pending

        // Detach onto a `.utility` worker so the ffmpeg C work doesn't block the actor's own
        // executor *and* doesn't compete with main-thread UI priority. We `await previous?.value`
        // first to enforce the serial-FIFO invariant.
        let task = Task<Int32, Never>.detached(priority: .utility) {
            await previous?.value
            return Int32(ffmpeg(args))
        }

        pending = Task<Void, Never> { _ = await task.value }

        return await task.value
    }
}

/// Owns the on-disk video cache, uses yt-dlp to fetch new ones, and surfaces progress so UI
/// can render a live transfer queue.
///
/// **Playback contract (CLAUDE.md §7 amended):**
/// Every download request calls `ensureDownloaded`. If `Documents/<id>.mp4` already
/// exists, we return immediately. Otherwise we kick off a yt-dlp run (via `PythonRunner`),
/// wait for it, write a `DownloadMetadata` xattr to the resulting file, and hand the local URL back to the resolver. This
/// sidesteps every PoT/cookie/HLS edge case in YouTube's CDN — the bytes are on disk before
/// AVPlayer ever sees them.
///
/// **Progress:** the manager publishes a single `AsyncStream<[DownloadTaskSnapshot]>` that any
/// observer can subscribe to. Both the Downloads screen and the per-tab badge read from it.
@available(iOS 17.0, *)
@Observable
@MainActor
final class DownloadManager: TemporaryDownloading {
    static let shared = DownloadManager()

    /// Live snapshots of every in-flight + recently completed download. Both the Downloads screen
    /// and the tab-badge model observe this directly via `@Observable`. Previous design used a
    /// single-consumer `AsyncStream` which silently dropped events for the second subscriber — that
    /// is why the Downloads tab looked empty while the badge was incrementing.
    private(set) var activeTasks: [DownloadTaskSnapshot] = []

    /// Per-video downloaded progress (0…1).
    private(set) var progressByVideoID: [String: Double] = [:]
    /// Per-video human-readable phase label ("video", "audio", "muxing"). yt-dlp downloads multiple
    /// streams sequentially under the same id, so we surface which one is currently in-flight to
    /// avoid the confusing "Downloading 100%" → "Downloading 0%" → "Downloading 100%" sequence.
    private(set) var phaseByVideoID: [String: String] = [:]

    private var tasks: [String: DownloadTaskSnapshot] = [:]

    /// Throttles the progress publish stream. yt-dlp emits progress events 5–10× per second per
    /// active download, and each `publish(snapshot:)` writes to 3 `@Observable` dictionaries plus
    /// rebuilds `activeTasks`. With several parallel downloads (Download All) the main actor was
    /// processing 30+ Observable mutations per second, and SwiftUI's per-mutation diff pass was
    /// what users felt as "scrolling stutters while downloading". We coalesce: if a video's most
    /// recent publish was less than `progressPublishMinInterval` ago, the new event is dropped.
    /// The next event arriving after the window catches up automatically, and terminal events
    /// (`finished` / `error`) bypass throttling entirely so we never miss a completion.
    private var lastProgressPublishedAt: [String: ContinuousClock.Instant] = [:]
    private let progressPublishMinInterval: Duration = .milliseconds(200)

    /// Coalesces concurrent `ensureDownloaded` calls for the same video so we don't start two
    /// downloads in parallel for the same id (which would race on the destination path).
    private var inflight: [String: Task<URL, Error>] = [:]
    private let preferences = UserPreferences()
    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "DownloadManager")
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    private init() {
        startMonitoringPath()
    }

    // MARK: - Public surface

    func isDownloading(videoID: String) -> Bool {
        inflight[videoID] != nil
    }

    /// Returns the local file only after its download and mux have finished.
    func localFile(for videoID: String) -> URL? {
        guard !isDownloading(videoID: videoID) else { return nil }
        let url = Self.fileURL(for: videoID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Either returns the existing local file URL, or downloads the video via yt-dlp and returns
    /// the freshly-written path. Coalesces parallel callers for the same `videoID`.
    ///
    /// `priority` controls where the download lands in `PythonRunner`'s queue. `.userInitiated`
    /// jumps ahead of pending `.background` items such as playlist Download All. The currently-running
    /// yt-dlp cannot be preempted, but the new high-priority item runs immediately after it.
    func ensureDownloaded(video: Video, priority: DownloadPriority = .background) async throws -> URL {
        try await ensureDownloaded(video: video, quality: nil, priority: priority)
    }

    func ensureDownloaded(video: Video, quality: VideoQuality, priority: DownloadPriority = .background) async throws -> URL {
        try await ensureDownloaded(video: video, quality: Optional(quality), priority: priority)
    }

    private func ensureDownloaded(video: Video, quality: VideoQuality?, priority: DownloadPriority) async throws -> URL {
        if let existing = localFile(for: video.id) {
            log.info("ensureDownloaded(\(video.id, privacy: .public)): cache hit, skipping yt-dlp")
            return existing
        }

        if let inflightTask = inflight[video.id] {
            log.info("ensureDownloaded(\(video.id, privacy: .public)): joining inflight task")
            return try await inflightTask.value
        }

        let path = currentPath ?? pathMonitor.currentPath
        try checkAllowedNetwork(path)
        let selectedQuality = quality ?? downloadQuality(for: path)
        log.info("ensureDownloaded(\(video.id, privacy: .public)): quality=\(selectedQuality.rawValue, privacy: .public) priority=\(String(describing: priority), privacy: .public)")

        let task = Task<URL, Error> { @MainActor [weak self] in
            guard let self else { throw YouTubeServiceError.unknown(NSError(domain: "DownloadManager", code: -1)) }
            defer { self.inflight[video.id] = nil }
            return try await self.runYoutubeDLDownload(video: video, quality: selectedQuality, priority: priority)
        }
        inflight[video.id] = task
        return try await task.value
    }

    /// Removes the downloaded file (if any) plus its SwiftData row. Safe to call when nothing is on
    /// disk — just no-ops. The `context` parameter is kept for source compatibility but the actual
    /// SwiftData delete now goes through the background `PersistenceWriter` so we don't block the
    /// main thread on the SQL queue.
    func deleteDownloaded(videoID: String, context: ModelContext) {
        let url = Self.fileURL(for: videoID)
        // File-system backed: removing the file drops its xattr too. `DownloadsStore` posts
        // the change notification on our behalf so the Downloads tab refreshes.
        DownloadsStore.shared.delete(at: url)
        log.info("Deleted download \(videoID, privacy: .public)")
    }

    func cancel(taskID: String) {
        guard let snapshot = tasks[taskID] else { return }
        tasks[taskID] = nil
        publishSnapshots()
        // Keep the video reserved until the worker finishes cleaning up its files.
        inflight[snapshot.videoID]?.cancel()
    }

    // MARK: - TemporaryDownloading

    /// Legacy path retained to satisfy the resolver protocol. The new resolver calls
    /// `ensureDownloaded` directly; this is just a thin wrapper.
    func downloadTemporary(videoID: String, format: VideoFormat) async throws -> URL {
        let placeholder = Video(
            id: videoID,
            title: videoID,
            channelID: "",
            channelName: "",
            channelThumbnailURL: nil,
            thumbnailURL: nil,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        return try await ensureDownloaded(video: placeholder)
    }

    // MARK: - yt-dlp execution

    private func runYoutubeDLDownload(video: Video, quality: VideoQuality, priority: DownloadPriority = .background) async throws -> URL {
        let startedAt = ContinuousClock.now
        log.info("yt-dlp[\(video.id, privacy: .public)] runYoutubeDLDownload start quality=\(quality.rawValue, privacy: .public)")
        let snapshotID = UUID().uuidString
        log.debug("yt-dlp[\(video.id, privacy: .public)] snapshotID=\(snapshotID, privacy: .public) → state=queued")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID,
            videoID: video.id,
            title: video.title,
            state: .queued,
            createdAt: .now
        ))

        let destination = Self.fileURL(for: video.id)
        let downloadsDir = destination.deletingLastPathComponent()
        log.debug("yt-dlp[\(video.id, privacy: .public)] destination=\(destination.path, privacy: .public)")

        // Pre-download filesystem work — creating the dir and scanning for stale siblings — runs
        // on a `.utility` background task instead of blocking the main actor. With several
        // parallel downloads this saves measurable scroll-hitch time on every Download All tap.
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            } catch {
                // Best-effort — directory probably already exists from a prior download.
            }
        }.value
        await removeYtDlpIntermediates(at: destination)
        try Task.checkCancellation()
        async let thumbnail = Self.downloadThumbnailData(url: video.thumbnailURL)

        // Select the best video stream with audio. When the streams are separate, yt-dlp
        // writes each track and Swift muxes them using the in-process FFmpeg library.
        let formatString = Self.formatString(for: quality)
        log.debug("yt-dlp[\(video.id, privacy: .public)] format selector=\(formatString, privacy: .public)")
        // Output template includes `%(format_id)s` so individual streams land at predictable paths
        // we can find afterwards. Final destination is set by us after the Swift-side mux.
        let outputTemplate = destination.deletingPathExtension().path + ".%(format_id)s.%(ext)s"

        // yt-dlp argv. We force mp4 output, point `-o` at our canonical Downloads/<id>.mp4 path,
        // skip writing playlist info, and feed the cleanest possible argument set. The package's
        // global yt_dlp(argv:) routes through Python and intercepts subprocess.Popen for ffmpeg/ffprobe,
        // so the in-tree FFmpegSupport library handles muxing transparently.
        //
        // `--no-check-certificates` is required because the embedded Python runtime (Python-iOS)
        // doesn't ship with a CA cert bundle on a path OpenSSL expects, so verification fails with
        // `CERTIFICATE_VERIFY_FAILED` on the first YouTube API request. We accept the trade-off
        // because (a) the only host we talk to is youtube.com / googlevideo.com, (b) this is a
        // sideload/personal app, and (c) the alternative is shipping certifi's cacert.pem and
        // setting `SSL_CERT_FILE` ourselves — that can come later.
        //
        // **No `--cookies` flag** — counter-intuitive, but yt-dlp's safety check
        // ("Skipping client X since it does not support cookies") removes the `tv_simply`,
        // `ios`, and `android_vr` clients from the fallback chain whenever a cookies file is
        // present. Those are exactly the clients that give us the broadest format coverage on
        // PoT-locked content. With cookies the surviving clients (`web_creator`, `mweb`)
        // honestly report "No video formats found" — the bottleneck was never cookie auth, it
        // was the JS-runtime-less n-cipher (CLAUDE.md §15.4). See `makeTemporaryCookiesFile`
        // doc-comment for the longer history of this experiment.
        let argv: [String] = [
            "https://www.youtube.com/watch?v=\(video.id)",
            "-f", formatString,
            "--format-sort-force", "-S", "height,fps",
            "-o", outputTemplate,
            "--no-playlist",
            "--no-progress",
            "--no-check-certificates",
            // **Player-client fallback chain + PoT bypass.** Two interrelated knobs:
            //
            // `player_client=…` — explicit list of YouTube player profiles to try, in fallback
            // order. The default yt-dlp list without a JS runtime is so narrow it commonly
            // hits "This video is not available" on kids / region-locked / age-gated videos.
            // We try clients with different PoT requirements:
            //   - `tv_simply` (TVHTML5 simply-embedded-player) — broadest format coverage.
            //   - `tv_embedded` — TV embedded player, often exempt from PoT enforcement.
            //   - `web_creator` — creator-mode profile, also frequently PoT-exempt.
            //   - `mweb` — mobile web, broad coverage including kids content.
            //   - `web_safari` — desktop Safari, useful for live + premium content.
            //   - `ios` — native iOS app profile.
            //   - `android_vr` — last-resort fallback (was the only default).
            //
            // `formats=missing_pot` — **critical**. As of late-2024 yt-dlp builds, formats that
            // YouTube has marked as requiring a Proof-of-Origin token are *filtered out by
            // default* on the assumption they'll return HTTP 403. With every format filtered,
            // yt-dlp falls through to "no usable formats" → `"This video is not available"`.
            // Setting `formats=missing_pot` tells yt-dlp "keep those formats anyway — I'll try."
            // In practice many still play because YouTube doesn't enforce PoT on every CDN
            // edge; the ones that do 403 fall through to the next client. Without this flag we
            // had `"...formats require a GVS PO Token which was not provided. They will be
            // skipped..."` in the log for every client we tried, leaving zero usable formats.
            "--extractor-args",
            "youtube:player_client=tv_simply,tv_embedded,web_creator,mweb,web_safari,ios,android_vr;formats=missing_pot",
            // **Concurrent fragment downloads.** For HLS/DASH streams yt-dlp downloads each
            // chunk sequentially by default — bumping this lets it fetch N fragments at once
            // over the same HTTP/2 connection. Doesn't change the total bytes pulled but cuts
            // wall-clock time, and is the closest thing to "parallel downloads" we can do
            // (Python/CPython requires single-thread interpreter access, so we can't run two
            // yt-dlp invocations side-by-side).
            //
            // Value is user-controlled via `UserPreferences.concurrentFragments`. We clamp here
            // as a defence-in-depth — `@AppStorage` can technically be poked to any Int.
            "--concurrent-fragments", "\(max(1, min(16, preferences.concurrentFragments)))",
            // With no FFmpeg executable, yt-dlp saves the requested tracks individually.
            "--compat-options", "no-direct-merge",
            "--no-abort-on-error",
            "--ffmpeg-location", "/dev/null/no-ffmpeg"
        ]

        log.info("yt-dlp[\(video.id, privacy: .public)] argv=\(argv.joined(separator: " "), privacy: .public)")
        log.debug("yt-dlp[\(video.id, privacy: .public)] → state=downloading(0)")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID,
            videoID: video.id,
            title: video.title,
            state: .downloading(progress: 0),
            createdAt: .now
        ))

        do {
            log.info("yt-dlp[\(video.id, privacy: .public)] invoking yt-dlp via PythonRunner")
            let videoID = video.id
            let workerStartedAt = OSAllocatedUnfairLock(initialState: ContinuousClock.Instant?.none)
            try await PythonRunner.shared.run(argv: argv, progress: { [weak self, log] dict in
                guard let self else { return }
                // CRITICAL: PythonKit's `PythonObject` is reference-counted on Python's GIL thread.
                // If we capture the `[String: PythonObject]` dict into a `Task { @MainActor in ... }`
                // closure, the objects get released on a *different* thread when the task ends, and
                // PyReference.deinit crashes inside `_PyInterpreterState_GET`. So we must extract
                // every value we care about into Swift-native primitives RIGHT HERE on the calling
                // thread, then ship only those primitives across the actor boundary.
                let status = String(dict["status"] ?? "") ?? ""
                let downloaded = Int(dict["downloaded_bytes"] ?? 0) ?? 0
                if status == "downloading", downloaded > 0,
                   let startedAt = workerStartedAt.withLock({ instant in
                       let startedAt = instant
                       instant = nil
                       return startedAt
                   }) {
                    let elapsed = startedAt.duration(to: .now)
                    log.info("yt-dlp[\(videoID, privacy: .public)] first download progress after \(String(describing: elapsed), privacy: .public) on worker")
                }
                let total = Int(dict["total_bytes"] ?? dict["total_bytes_estimate"] ?? 0) ?? 0
                let speed = Int(dict["speed"] ?? 0) ?? 0
                let eta = Int(dict["eta"] ?? 0) ?? 0
                // `filename` tells us which stream this hook is for: <id>.<itag>.mp4 vs <id>.<itag>.m4a.
                let filename = String(dict["filename"] ?? "") ?? ""
                let phase: String
                let lower = filename.lowercased()
                if lower.hasSuffix(".m4a") || lower.hasSuffix(".webm") && lower.contains("audio") {
                    phase = "audio"
                } else if lower.hasSuffix(".mp4") || lower.hasSuffix(".webm") {
                    phase = "video"
                } else {
                    phase = "stream"
                }
                Task { @MainActor [snapshotID, videoID = video.id, videoTitle = video.title] in
                    self.handleProgress(
                        status: status,
                        downloaded: downloaded,
                        total: total,
                        speed: speed,
                        eta: eta,
                        phase: phase,
                        snapshotID: snapshotID,
                        videoID: videoID,
                        videoTitle: videoTitle
                    )
                }
            }, log: { [weak self, log] level, message in
                // Bridge yt-dlp's Python logger to os_log so its diagnostics show up alongside ours.
                // Levels we get: debug / info / warning / error.
                if level == "error" {
                    log.error("yt-dlp: \(message, privacy: .public)")
                } else if level == "warning" {
                    log.notice("yt-dlp: \(message, privacy: .public)")
                } else {
                    log.info("yt-dlp: \(message, privacy: .public)")
                }
                // The "[Merger]" line is yt-dlp's last visible step before it hands off to ffmpeg.
                // ffmpeg runs CPU-bound on the device for 10–60s and emits no progress, so we flip
                // the progress overlay to a spinner ("Processing…") instead of leaving it at 100%.
                if message.contains("[Merger]") || message.contains("[ExtractAudio]") || message.contains("Fixup") {
                    let id = video.id
                    Task { @MainActor [weak self] in
                        self?.progressByVideoID.removeValue(forKey: id)
                    }
                }
            }, onStart: { [log] queuedAt in
                let now = ContinuousClock.now
                workerStartedAt.withLock { $0 = now }
                log.info("yt-dlp[\(videoID, privacy: .public)] worker started after \(String(describing: queuedAt.duration(to: now)), privacy: .public) in queue")
            }, priority: priority == .userInitiated ? .high : .low)
            log.info("yt-dlp[\(videoID, privacy: .public)] transfer finished")
            try Task.checkCancellation()
            try await finalizeYtDlpOutput(at: destination, videoID: video.id)
        } catch {
            let primaryError = error
            try? FileManager.default.removeItem(at: destination)
            await removeYtDlpIntermediates(at: destination)
            try Task.checkCancellation()
            log.error("yt-dlp[\(video.id, privacy: .public)] download failed: \(primaryError.localizedDescription, privacy: .private)")

            var recovered = false
            // YouTubeKit can pair higher-resolution video with separate audio. Give it a
            // chance before restricting the fallback to combined MP4 files.
            do {
                try await runYouTubeKitFallback(video: video, quality: quality, destination: destination, snapshotID: snapshotID)
                recovered = true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try Task.checkCancellation()
                log.error("[fallback] YouTubeKit download failed for \(video.id, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }

            if !recovered, (primaryError as? YtDlpDownloadError)?.httpStatus == 403, quality != .audioOnly {
                do {
                    try await runProbedMP4Fallback(video: video, quality: quality, destination: destination, snapshotID: snapshotID)
                    recovered = true
                } catch {
                    try Task.checkCancellation()
                    log.notice("[fallback] probed MP4 download failed for \(video.id, privacy: .public): \(error.localizedDescription, privacy: .private)")
                }
            }

            if !recovered {
                publish(snapshot: DownloadTaskSnapshot(
                    id: snapshotID, videoID: video.id, title: video.title,
                    state: .failed(primaryError.localizedDescription), createdAt: .now
                ))
                throw primaryError
            }
        }

        let thumbnailData = await thumbnail
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        log.info("yt-dlp[\(video.id, privacy: .public)] file on disk: size=\(fileSize, privacy: .public) bytes path=\(destination.path, privacy: .public)")

        log.debug("yt-dlp[\(video.id, privacy: .public)] writing download metadata xattr")
        persistDownloaded(video: video, fileURL: destination, thumbnail: thumbnailData)

        log.debug("yt-dlp[\(video.id, privacy: .public)] → state=completed")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID,
            videoID: video.id,
            title: video.title,
            state: .completed(destination),
            createdAt: .now
        ))
        // Drop the completed entry from `tasks` after a moment so the in-progress section clears.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.tasks[snapshotID] = nil
            self.publishSnapshots()
        }

        let elapsed = startedAt.duration(to: .now)
        log.info("yt-dlp[\(video.id, privacy: .public)] SUCCESS in \(String(describing: elapsed), privacy: .public) → \(destination.path, privacy: .public)")
        return destination
    }

    private func finalizeYtDlpOutput(at destination: URL, videoID: String) async throws {
        let downloadsDir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        // Split tracks use <id>.<video_id>+<audio_id>.f<track_id>.<ext>. Scan off-main
        // since the download directory can contain hundreds of files.
        let intermediates: [URL] = await Task.detached(priority: .utility) {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("\(stem).") } ?? []
            // Don't include the canonical destination itself in mux inputs.
            return candidates.filter {
                $0.path != destination.path && !$0.pathExtension.hasPrefix("part")
                    && $0.pathExtension != "ytdl"
            }
        }.value
        log.debug("yt-dlp[\(videoID, privacy: .public)] candidate files: \(intermediates.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")

        let videoFile = intermediates.first { url in
            ["mp4", "webm", "mkv"].contains(url.pathExtension.lowercased()) &&
            !url.lastPathComponent.contains(".\(stem).m4a") &&
            url.pathExtension.lowercased() != "m4a"
        }
        let audioFile = intermediates.first { ["m4a", "mp3", "aac", "opus"].contains($0.pathExtension.lowercased()) }

        if let videoFile, let audioFile {
            log.info("yt-dlp[\(videoID, privacy: .public)] muxing video=\(videoFile.lastPathComponent, privacy: .public) audio=\(audioFile.lastPathComponent, privacy: .public)")
            try await muxToDestination(video: videoFile, audio: audioFile, destination: destination)
            // Clean up the per-stream intermediates off-main — `removeItem` for each one is sync,
            // and with N parallel downloads finishing back-to-back this can add up.
            let toRemove = intermediates
            await Task.detached(priority: .utility) {
                for url in toRemove {
                    try? FileManager.default.removeItem(at: url)
                }
            }.value
        } else if let single = intermediates.first, !single.lastPathComponent.contains("+") {
            // Split track filenames include the merged format ID (video+audio).
            // A lone split track must fall through to the YouTubeKit fallback.
            log.info("yt-dlp[\(videoID, privacy: .public)] single-file mode (no mux needed): \(single.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: single, to: destination)
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "FreeTube.DownloadManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "yt-dlp did not produce a complete download."]
            )
        }
    }

    private func removeYtDlpIntermediates(at destination: URL) async {
        let directory = destination.deletingLastPathComponent()
        let prefix = destination.deletingPathExtension().lastPathComponent + "."
        await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files where file != destination && file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }.value
    }

    /// Renders a yt-dlp progress event into a snapshot and a log line. Takes Swift primitives —
    /// PythonObject extraction happens upstream on Python's GIL thread, see the progress closure in
    /// `runYoutubeDLDownload`.
    private func handleProgress(
        status: String,
        downloaded: Int,
        total: Int,
        speed: Int,
        eta: Int,
        phase: String,
        snapshotID: String,
        videoID: String,
        videoTitle: String
    ) {
        guard let snapshot = tasks[snapshotID], case .downloading = snapshot.state else { return }
        let progress = total > 0 ? max(0, min(1, Double(downloaded) / Double(total))) : 0

        if status == "downloading" {
            // Throttle: skip if this video's last publish was within the min-interval window. The
            // next callback that arrives outside the window will pick up the latest progress
            // value, so the UI stays accurate, just less twitchy.
            let now = ContinuousClock.now
            if let last = lastProgressPublishedAt[videoID], (now - last) < progressPublishMinInterval {
                return
            }
            lastProgressPublishedAt[videoID] = now

            log.debug("yt-dlp[\(videoID, privacy: .public)] \(phase, privacy: .public) progress: \(String(format: "%.1f", progress * 100), privacy: .public)% (\(downloaded, privacy: .public)/\(total, privacy: .public) B) speed=\(speed, privacy: .public) B/s eta=\(eta, privacy: .public)s")
            // Avoid an Observable write when the phase didn't actually change. SwiftUI's
            // `@Observable` macro fires on every assignment, even to the same value.
            if phaseByVideoID[videoID] != phase {
                phaseByVideoID[videoID] = phase
            }
            publish(snapshot: DownloadTaskSnapshot(
                id: snapshotID,
                videoID: videoID,
                title: videoTitle,
                state: .downloading(progress: progress),
                createdAt: .now
            ))
        } else if status == "finished" {
            log.info("yt-dlp[\(videoID, privacy: .public)] \(phase, privacy: .public) finished — moving to next phase")
            // Clear known progress so the UI overlay flips from "Downloading 100%" to a spinner.
            progressByVideoID.removeValue(forKey: videoID)
            // Reset throttle so the next phase (audio after video, or mux) gets its first event
            // through immediately rather than waiting out the window from the previous phase.
            lastProgressPublishedAt.removeValue(forKey: videoID)
            // Note: don't clear phase here — keep showing the last label until the next downloading
            // event sets it.
        } else if status == "error" {
            log.error("yt-dlp[\(videoID, privacy: .public)] progress hook reports error")
            lastProgressPublishedAt.removeValue(forKey: videoID)
        } else {
            log.debug("yt-dlp[\(videoID, privacy: .public)] progress hook status=\(status, privacy: .public)")
        }
    }

    // MARK: - SwiftData

    private func persistDownloaded(video: Video, fileURL: URL, thumbnail: Data?) {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        log.debug("persistDownloaded(\(video.id, privacy: .public)) thumbnailBytes=\(thumbnail?.count ?? 0, privacy: .public) size=\(size, privacy: .public)")
        // File-system + xattr backed (no SwiftData): the metadata travels with the file.
        // `DownloadsStore.write` compresses the thumbnail to ~10 KB JPEG and posts the
        // change notification so the Downloads tab re-renders.
        DownloadsStore.shared.write(
            videoID: video.id,
            title: video.title,
            channelName: video.channelName,
            formatID: "ytdl",
            originalURL: nil,
            rawThumbnail: thumbnail,
            at: fileURL
        )
        log.info("persistDownloaded(\(video.id, privacy: .public)) wrote xattr size=\(size, privacy: .public) bytes")
        enforceCacheLimit()
    }

    /// Runs the LRU eviction sweep against the user's current cache-size preference. The newest
    /// download is preserved (the one we just persisted), so this never sabotages the playback
    /// request that triggered it. Now driven by `DownloadsStore` over the filesystem.
    private func enforceCacheLimit() {
        let limit = UserPreferences().downloadCacheLimit.bytes
        DownloadsStore.shared.enforceCacheLimit(limit)
    }

    private nonisolated static func downloadThumbnailData(url: URL?) async -> Data? {
        guard let url else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    // MARK: - YouTubeKit / TVHTML5 fallback

    private func runProbedMP4Fallback(video: Video, quality: VideoQuality, destination: URL, snapshotID: String) async throws {
        let watchURL = "https://www.youtube.com/watch?v=\(video.id)"
        let media = try await YtDlpInfoService().probe(url: watchURL)
        try Task.checkCancellation()
        let formats = Self.probedMP4Formats(media.formats, maxHeight: quality.heightCap)

        let partial = destination.deletingPathExtension().appendingPathExtension("fallback.part")
        defer { try? FileManager.default.removeItem(at: partial) }
        var attempted: Set<URL> = []
        var lastError: Error = YouTubeServiceError.streamExtractionFailed

        for format in formats {
            guard attempted.count < 3 else { break }
            guard let url = format.url, attempted.insert(url).inserted else { continue }
            try Task.checkCancellation()
            log.info("[fallback] Trying combined MP4 format=\(format.id, privacy: .public) height=\(format.height ?? 0, privacy: .public)")
            publish(snapshot: DownloadTaskSnapshot(
                id: snapshotID, videoID: video.id, title: video.title,
                state: .downloading(progress: 0), createdAt: .now
            ))
            phaseByVideoID[video.id] = "stream"
            lastProgressPublishedAt.removeValue(forKey: video.id)
            do {
                try await downloadStream(
                    from: url, to: partial, videoID: video.id, snapshotID: snapshotID,
                    title: video.title, useTVHTML5UserAgent: false
                )
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: partial, to: destination)
                return
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    private static func probedMP4Formats(_ formats: [RemoteFormat], maxHeight: Int?) -> [RemoteFormat] {
        formats.filter { format in
            guard format.isProgressive, format.protocolKind == .https,
                  format.url?.scheme?.lowercased() == "https", format.url?.host != nil,
                  format.ext.lowercased() == "mp4",
                  let vcodec = format.vcodec?.lowercased(), vcodec.hasPrefix("avc1") || vcodec == "h264",
                  let acodec = format.acodec?.lowercased(), acodec.hasPrefix("mp4a") || acodec == "aac" else { return false }
            return maxHeight.map { (format.height ?? .max) <= $0 } ?? true
        }
        .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }

    /// Fallback path that runs when yt-dlp fails to produce a usable file. Uses
    /// `VideoService.fetchInfoViaTVHTML5` (which goes through `YouTubeKitClient.tvHtmlModel`
    /// — TVHTML5_SIMPLY_EMBEDDED_PLAYER context, the client profile YouTube exempts from PoT
    /// enforcement) to get fresh stream URLs, then downloads the bytes directly via
    /// `URLSession`. If only adaptive (video-only + audio-only) streams are available, the
    /// two pieces are muxed back into a single `.mp4` via the same `FFmpegRunner` we use for
    /// yt-dlp output.
    ///
    /// Why this works when yt-dlp doesn't: yt-dlp's defensive filter strips formats marked as
    /// requiring a Proof-of-Origin token before download even starts. The TVHTML5 client
    /// returns URLs that aren't tagged with that requirement, so YouTubeKit happily hands them
    /// to us and URLSession fetches them like any other HTTPS resource.
    private func runYouTubeKitFallback(video: Video, quality: VideoQuality, destination: URL, snapshotID: String) async throws {
        log.info("yt-dlp[\(video.id, privacy: .public)] fallback: fetching stream info via YouTubeKit")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID, videoID: video.id, title: video.title,
            state: .downloading(progress: 0), createdAt: .now
        ))
        phaseByVideoID[video.id] = "stream"

        let formats = await fetchFallbackFormats(videoID: video.id)
        log.info("yt-dlp[\(video.id, privacy: .public)] fallback: \(formats.count, privacy: .public) usable formats")
        guard !formats.isEmpty else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        let maxHeight = quality == .audioOnly ? 1080 : quality.heightCap ?? .max
        let videoFormat = pickBestVideoOnly(formats: formats, maxHeight: maxHeight)
        let audioFormat = pickBestAudioOnly(formats: formats)

        try? FileManager.default.removeItem(at: destination)

        if let progressive = pickBestProgressive(formats: formats, maxHeight: maxHeight),
           let url = progressive.url,
           audioFormat == nil || (progressive.height ?? 0) >= (videoFormat?.height ?? 0) {
            log.info("yt-dlp[\(video.id, privacy: .public)] fallback: progressive height=\(progressive.height ?? 0, privacy: .public)")
            try await downloadStream(from: url, to: destination, videoID: video.id, snapshotID: snapshotID, title: video.title)
            return
        }

        // **Strategy 2: adaptive — separate video-only and audio-only streams.** Required for
        // anything ≥ 720p (YouTube doesn't ship progressive at those resolutions). Download
        // both, then mux with ffmpeg `-c copy` so we get a single playable mp4.
        guard let videoFormat, let videoURL = videoFormat.url,
              let audioFormat, let audioURL = audioFormat.url else {
            log.error("yt-dlp[\(video.id, privacy: .public)] fallback: no suitable formats found")
            throw YouTubeServiceError.streamExtractionFailed
        }

        let downloadsDir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let videoFile = downloadsDir.appendingPathComponent("\(stem).fallback.video.mp4")
        let audioFile = downloadsDir.appendingPathComponent("\(stem).fallback.audio.m4a")
        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }

        log.info("yt-dlp[\(video.id, privacy: .public)] fallback: adaptive video height=\(videoFormat.height ?? 0, privacy: .public)")
        phaseByVideoID[video.id] = "video"
        try await downloadStream(from: videoURL, to: videoFile, videoID: video.id, snapshotID: snapshotID, title: video.title)
        phaseByVideoID[video.id] = "audio"
        try await downloadStream(from: audioURL, to: audioFile, videoID: video.id, snapshotID: snapshotID, title: video.title)
        phaseByVideoID[video.id] = "muxing"
        progressByVideoID.removeValue(forKey: video.id)

        try await muxToDestination(video: videoFile, audio: audioFile, destination: destination)
    }

    /// Two-tier format fetch for the fallback path.
    ///
    /// 1. **`fetchInfoViaTVHTML5`** — uses `YouTubeKitClient.tvHtmlModel` (TVHTML5_SIMPLY_
    ///    EMBEDDED_PLAYER context). PoT-exempt on the video-info side. Cheap: one HTTP call, no
    ///    player-JS scrape. Caveat: the response carries `signatureCipher`-protected URLs for
    ///    some videos and YouTubeKit drops those (no JS runtime to decode them on iOS), so on
    ///    cipher-heavy content we get back zero formats.
    ///
    /// 2. **`fetchInfoWithFormats`** — uses `VideoInfosWithDownloadFormatsResponse`, which
    ///    additionally scrapes the YouTube player.js and decodes signature ciphers natively
    ///    in YouTubeKit. Slower (two HTTP calls + JS parsing) but produces direct URLs even
    ///    for cipher-protected formats. Falls through to this tier when TVHTML5 returned
    ///    nothing usable — exactly the case the Baby-Shark video hit.
    ///
    /// Either tier failing silently returns an empty array; the caller treats that as "no
    /// fallback path available" and surfaces `streamExtractionFailed`.
    private func fetchFallbackFormats(videoID: String) async -> [VideoFormat] {
        let service = VideoService()
        do {
            let info = try await service.fetchInfoViaTVHTML5(id: videoID)
            let usable = info.formats.filter { $0.url != nil }
            if !usable.isEmpty {
                log.info("[fallback] TVHTML5 returned \(info.formats.count, privacy: .public) formats, \(usable.count, privacy: .public) with URLs")
                return usable
            }
            log.notice("[fallback] TVHTML5 returned \(info.formats.count, privacy: .public) formats but 0 with direct URLs (cipher-protected); trying player.js scrape")
        } catch {
            log.notice("[fallback] TVHTML5 fetch failed: \(String(describing: error), privacy: .public); trying player.js scrape")
        }
        do {
            let result = try await service.fetchInfoWithFormats(id: videoID)
            let usable = result.formats.filter { $0.url != nil }
            log.info("[fallback] fetchInfoWithFormats returned \(result.formats.count, privacy: .public) formats, \(usable.count, privacy: .public) with URLs")
            return usable
        } catch {
            log.error("[fallback] fetchInfoWithFormats failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Downloads a single stream to `destination` with periodic progress updates fed into
    /// `handleProgress` so the UI's progress bar moves.
    private func downloadStream(
        from url: URL, to destination: URL, videoID: String, snapshotID: String, title: String,
        useTVHTML5UserAgent: Bool = true
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        var request = URLRequest(url: url)
        // Match the TVHTML5_SIMPLY_EMBEDDED_PLAYER user-agent we set on `tvHtmlModel`.
        // The CDN occasionally rejects requests whose UA doesn't match the client that minted
        // the URL.
        if useTVHTML5UserAgent {
            request.setValue("Mozilla/5.0 (PlayStation; PlayStation 4/12.55) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        }

        let startedAt = ContinuousClock.now
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        guard http.statusCode == 200 else {
            log.error("[fallback] Unexpected HTTP status \(http.statusCode, privacy: .public) from \(url.host ?? "?", privacy: .public)")
            throw URLError(.badServerResponse)
        }
        if let mimeType = http.mimeType, mimeType.hasPrefix("text/") || mimeType == "application/json" {
            throw URLError(.cannotDecodeContentData)
        }
        let expected = http.expectedContentLength
        let total = expected > 0 ? Int(expected) : 0

        // Write the streamed bytes to disk in 64 KB chunks so we don't buffer the entire
        // video in memory. Emit progress on every chunk; `handleProgress` itself throttles
        // the UI publish rate to ~5/sec.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var written = 0
        for try await byte in asyncBytes {
            if written == 0, buffer.isEmpty {
                let elapsed = startedAt.duration(to: .now)
                log.info("[fallback][\(videoID, privacy: .public)] first download byte after \(String(describing: elapsed), privacy: .public)")
            }
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                handleProgress(
                    status: "downloading",
                    downloaded: written,
                    total: total,
                    speed: 0,
                    eta: 0,
                    phase: phaseByVideoID[videoID] ?? "stream",
                    snapshotID: snapshotID,
                    videoID: videoID,
                    videoTitle: title
                )
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
        }
        guard written > 0, total == 0 || written == total else {
            throw URLError(.cannotDecodeContentData)
        }
        try handle.close()
        log.info("[fallback] wrote \(written, privacy: .public) bytes to \(destination.lastPathComponent, privacy: .public)")
    }

    /// Picks the highest-resolution progressive (single-file, both-tracks) format whose height
    /// is within the user's quality cap. nil if YouTube didn't return any combined stream.
    private func pickBestProgressive(formats: [VideoFormat], maxHeight: Int) -> VideoFormat? {
        formats
            .filter { $0.containsBothTracks && $0.url != nil }
            .filter { ($0.height ?? Int.max) <= maxHeight }
            .max { ($0.height ?? 0) < ($1.height ?? 0) }
    }

    /// Highest-resolution video-only format within the cap. Prefer MP4 at equal resolution.
    private func pickBestVideoOnly(formats: [VideoFormat], maxHeight: Int) -> VideoFormat? {
        let candidates = formats.filter { $0.isVideoOnly && $0.url != nil && ($0.height ?? Int.max) <= maxHeight }
        return candidates.max { lhs, rhs in
            let lhsHeight = lhs.height ?? 0
            let rhsHeight = rhs.height ?? 0
            if lhsHeight != rhsHeight { return lhsHeight < rhsHeight }
            return !lhs.mimeType.lowercased().contains("mp4") && rhs.mimeType.lowercased().contains("mp4")
        }
    }

    /// Highest-bitrate audio-only m4a/mp4. Same mp4-preference rule as video to keep the mux
    /// in `-c copy` territory.
    private func pickBestAudioOnly(formats: [VideoFormat]) -> VideoFormat? {
        let candidates = formats.filter { $0.isAudioOnly && $0.url != nil }
        let mp4s = candidates.filter { $0.mimeType.lowercased().contains("mp4") || $0.mimeType.lowercased().contains("m4a") }
        let pool = mp4s.isEmpty ? candidates : mp4s
        return pool.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }

    // MARK: - Muxing (direct ffmpeg call, no Python)

    /// Combines a video-only mp4 with an audio-only m4a into a single mp4 using `ffmpeg -c copy`.
    ///
    /// **Why ffmpeg:** yt-dlp delivers YouTube's DASH-fragmented mp4. AVFoundation parses these
    /// containers with halved frame rate (per-frame PTS values in the fragmented mp4 read as 2× the
    /// real values), so any AVAssetExportSession/AVAssetReader-based mux produces a doubled-duration
    /// output. `ffmpeg -c copy` is the canonical fixup — it rewrites the moov atom into a regular
    /// (non-fragmented) mp4 with correct timestamps without re-encoding.
    ///
    /// **Why not via yt-dlp's Popen:** the previous hang we hit was Python's `Popen.communicate`
    /// never returning after ffmpeg's `longjmp` tore through the Python interpreter's stack. Calling
    /// `FFmpegSupport.ffmpeg(_:)` *directly* from Swift sidesteps Python entirely — the longjmp
    /// lands at the C `setjmp` inside the library and control returns to Swift cleanly.
    private func muxToDestination(video: URL, audio: URL, destination: URL) async throws {
        log.info("mux via ffmpeg: video=\(video.lastPathComponent, privacy: .public) audio=\(audio.lastPathComponent, privacy: .public)")
        try? FileManager.default.removeItem(at: destination)

        let args: [String] = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-i", video.path,
            "-i", audio.path,
            "-c", "copy",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-movflags", "+faststart",
            destination.path
        ]
        log.info("ffmpeg argv: \(args.joined(separator: " "), privacy: .public)")

        let startedAt = ContinuousClock.now
        // Route every ffmpeg invocation through the shared `FFmpegRunner` actor. ffmpeg's C
        // library is **not** thread-safe — the `+faststart` post-pass crashes on concurrent
        // calls (see FFmpegRunner doc comment). Plain `Task.detached` here was the bug: each
        // parallel playlist download finishing its yt-dlp step fired its own ffmpeg detach,
        // and two of them stomping global buffers blew up inside `ff_format_shift_data`.
        let exitCode = await FFmpegRunner.shared.run(args)
        let elapsed = startedAt.duration(to: .now)
        log.info("ffmpeg[\(destination.lastPathComponent, privacy: .public)] returned exit=\(exitCode, privacy: .public) after \(String(describing: elapsed), privacy: .public) including queue time")

        guard exitCode == 0 else {
            log.error("ffmpeg failed exit=\(exitCode, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            log.error("ffmpeg returned 0 but output missing at \(destination.path, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }

        // Sanity-log the final duration so any future regression is obvious in os_log.
        let asset = AVURLAsset(url: destination)
        if let dur = try? await asset.load(.duration) {
            log.info("ffmpeg-muxed file duration=\(dur.seconds, privacy: .public)s path=\(destination.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - File locations + format selection

    /// Canonical on-disk location for a downloaded video. Files land at the **Documents
    /// root** so they're visible in the system Files app under "On My iPhone" /
    /// "On My iPad" (gated by `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
    /// in Info.plist). Every video gets a fixed `mp4` extension because yt-dlp's merger
    /// produces an mp4 container.
    static func fileURL(for videoID: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("\(videoID).mp4")
    }

    /// Materializes a temporary Netscape-format `cookies.txt` from the user's stored YouTube
    /// cookie header, suitable for yt-dlp's `--cookies <path>` flag.
    ///
    /// **Currently unused.** Kept as a reference because the experiment that called it was
    /// instructive — and someone will probably try it again. Summary of why it's not wired up:
    ///
    /// On 2026-05-19 we briefly added `--cookies <tmpfile>` to the yt-dlp argv in
    /// `runYoutubeDLDownload` on the theory that authenticated requests would get more
    /// permissive PoT enforcement from YouTube and rescue currently-403ing videos. yt-dlp
    /// rejected this combination with the safety check `"Skipping client X since it does not
    /// support cookies"` and dropped three of our seven configured player clients —
    /// specifically `tv_simply`, `ios`, and `android_vr`, which are exactly the clients that
    /// give us the broadest format coverage on PoT-locked content. With cookies the surviving
    /// clients (`web_creator`, `mweb`) honestly reported `"No video formats found!"` for the
    /// same videos that without cookies returned 23+ formats (then 403'd at download). Net
    /// regression — we lost format extraction without gaining playable URLs.
    ///
    /// **The actual bottleneck is the n-cipher (CLAUDE.md §15.4), not auth.** Without a JS
    /// runtime to solve YouTube's n-challenge, every URL we extract is either 403'd at the CDN
    /// or stripped out before extraction. Cookies don't substitute for a PoT token.
    ///
    /// Returns `nil` when there's no stored header (anonymous user). The caller would be
    /// responsible for deleting the file (via `defer`) after the yt-dlp invocation returns;
    /// file lives in `FileManager.default.temporaryDirectory` with `chmod 0600`. Note that
    /// even brief disk presence is a CLAUDE.md §2.5 deviation.
    private static func makeTemporaryCookiesFile() -> URL? {
        guard let header = CookieStore.shared.loadHeader() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-dlp-cookies-\(UUID().uuidString).txt")
        var lines = [
            "# Netscape HTTP Cookie File",
            "# Generated by FreeTube; deleted on yt-dlp completion.",
        ]
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            // domain TAB includeSubdomain TAB path TAB secure TAB expires TAB name TAB value
            lines.append(".youtube.com\tTRUE\t/\tTRUE\t2147483647\t\(name)\t\(value)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// `bestvideo*` considers progressive and video-only tracks together. yt-dlp adds the
    /// audio-only track only when the chosen video has no embedded audio.
    private static func formatString(for quality: VideoQuality) -> String {
        if quality == .audioOnly {
            return "bestaudio[ext=m4a]/bestaudio"
        }
        let cap = quality.heightCap.map { "[height<=\($0)]" } ?? ""
        return "bestvideo*\(cap)+bestaudio[ext=m4a]/best\(cap)"
    }

    // MARK: - Networking gate + snapshots

    private func startMonitoringPath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in self.currentPath = path }
        }
        pathMonitor.start(queue: DispatchQueue(label: "DownloadManager.path"))
    }

    var currentDownloadQuality: VideoQuality {
        downloadQuality(for: currentPath ?? pathMonitor.currentPath)
    }

    private func downloadQuality(for path: NWPath) -> VideoQuality {
        if path.status != .satisfied || (path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)) {
            return preferences.cellularDownloadQuality
        }
        return preferences.wifiDownloadQuality
    }

    private func checkAllowedNetwork(_ path: NWPath) throws {
        // Permissive default: if the user allows cellular, never block.
        if preferences.allowCellularDownloads { return }
        if path.usesInterfaceType(.wifi) { return }
        throw YouTubeServiceError.network(NSError(
            domain: "FreeTube.DownloadManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Cellular downloads are disabled in Settings, but Wi-Fi isn't currently available."]
        ))
    }

    private func publish(snapshot: DownloadTaskSnapshot) {
        tasks[snapshot.id] = snapshot
        if case .downloading(let value) = snapshot.state {
            progressByVideoID[snapshot.videoID] = value
        } else if case .completed = snapshot.state {
            progressByVideoID.removeValue(forKey: snapshot.videoID)
        } else if case .failed = snapshot.state {
            progressByVideoID.removeValue(forKey: snapshot.videoID)
        }
        publishSnapshots()
    }

    /// Publish a snapshot owned by a different downloader (currently just `URLDownloadManager`)
    /// into the shared transfer-queue. The convention is that **external snapshots use an
    /// `id` prefixed with `"fetch-"`** so cancel-routing in `DownloadsViewModel.cancel` knows
    /// to delegate back to the originating manager. Removal is handled by the publisher —
    /// when an external download finishes, it calls `removeExternalSnapshot(id:)` after the
    /// usual 2-second auto-dismiss delay (matching the YouTube flow's UX).
    func publishExternal(snapshot: DownloadTaskSnapshot) {
        publish(snapshot: snapshot)
    }

    /// Remove a previously-published external snapshot. Called by the originating downloader
    /// once it's decided the row should disappear from the transfer queue. No-op if the id
    /// is unknown (terminal snapshots may have already been swept).
    func removeExternalSnapshot(id: String) {
        tasks[id] = nil
        publishSnapshots()
    }

    private func publishSnapshots() {
        activeTasks = Array(tasks.values).sorted { $0.createdAt > $1.createdAt }
        log.debug("publishSnapshots: \(self.activeTasks.count, privacy: .public) entries")
    }
}
