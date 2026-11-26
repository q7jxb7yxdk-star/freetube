import Foundation
import AVFoundation
import Combine
import Kingfisher
import OSLog
import SwiftData
import UIKit

/// CLAUDE.md §8: single source of truth for playback. Injected via SwiftUI environment.
/// Mini player and full-screen player both observe this object — neither owns its own `AVPlayer`.
///
/// Combine is used **only** here for `AVPlayer` time-observer bridging, per CLAUDE.md §2.9.
@available(iOS 17.0, *)
@MainActor
@Observable
final class PlayerStateManager {
    enum LoadState: Equatable {
        case idle
        case resolving
        case readyToPlay
        case failed(String)
    }

    private enum StreamSource: String, CaseIterable, Sendable {
        case ios = "IOS"
        case tv = "TVHTML5"
        case formats = "YouTubeKit formats"
        case ytDlpVisionOS = "yt-dlp visionos"
        case ytDlp = "yt-dlp"
    }

    private nonisolated struct StreamCandidate: Sendable {
        enum Kind: String, Sendable {
            case hlsMaster = "HLS master"
            case hls = "HLS"
            case mp4 = "MP4"
        }

        let url: URL
        let source: StreamSource
        let formatID: String
        let kind: Kind
        let height: Int?
        let width: Int?
        var manifestResolutions: [Int] = []

        var resolution: Int? { height.map { min(width ?? $0, $0) } }
    }

    private struct HLSPlayback {
        let candidate: StreamCandidate
        var playlist: HLSResolutionPlaylist?
        let loader: HLSResolutionResourceLoader?
        let resolution: Int?

        var resolutions: [Int] { playlist?.resolutions ?? Array(candidate.manifestResolutions.reversed()) }
    }

    // MARK: - Published state

    private(set) var currentVideo: Video?
    private(set) var isFromURLFile = false
    /// Cached artwork for the current video. Used both to populate `MPNowPlayingInfoCenter`
    /// (lock-screen + Control Center) and (in the future) any in-app UI that wants a UIImage rather
    /// than the SwiftUI `Image`. Refreshed when the current video changes.
    private(set) var currentArtwork: UIImage?
    private(set) var loadState: LoadState = .idle
    private(set) var isPlaying: Bool = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var playbackResolution: Int?
    private(set) var selectedStreamResolution: Int?
    var resolutionChangeFailed = false
    var streamResolutionOptions: [Int] {
        guard loadState == .readyToPlay, activeStreamKind != nil, !isChangingResolution else { return [] }
        if let activeHLSPlayback { return activeHLSPlayback.resolutions }
        let resolutions = Set(fixedStreamCandidates.compactMap(\.resolution).filter { $0 > 0 })
        return resolutions.count > 1 ? resolutions.sorted(by: >) : []
    }
    var miniPlayerVisible: Bool = false
    var fullScreenPresented: Bool = false

    // MARK: - AVPlayer

    /// `AVQueuePlayer` to unlock `advanceToNextItem()` and queue introspection for future preload.
    /// IMPORTANT: don't use `replaceCurrentItem(with:)` to load tracks — it's a no-op on
    /// `AVQueuePlayer` when the internal queue is empty (which is our usual state). Use the
    /// `removeAllItems()` + `insert(_:after:)` pattern via `swap(to:)` below.
    let player = AVQueuePlayer()

    // MARK: - Collaborators

    let queue: QueueManager
    private let preferences: UserPreferences
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlayerStateManager")

    /// Sticky "this queue is endless" intent. Set to `true` whenever the user loads a video
    /// without explicitly skipping recommendations (Home / Search / Mini-player / row taps),
    /// and `false` for curated batch actions like playlist's Play all / Shuffle all. Drives:
    ///   1. The per-load `fillQueueWithRecommendations` call in `resolveAndPlay`.
    ///   2. The auto-advance dead-end recovery in `playNext()` — when the queue runs out and
    ///      repeat is off, we fire a fresh recs fetch using the queue's last item as a seed,
    ///      then advance once new items land. That gives the requested "endless queue" feel:
    ///      whenever you reach the latest item, recommendations refill behind it.
    private var queueAcceptsRecommendations = true

    private var playbackResolutionTask: Task<Void, Never>?
    private var resolutionChangeTask: Task<Void, Never>?
    private var hlsPlaylistTask: Task<Void, Never>?
    private var isChangingResolution = false
    private var activeStreamKind: StreamCandidate.Kind?
    private var activeHLSPlayback: HLSPlayback?
    private var fixedStreamCandidates: [StreamCandidate] = []
    private var shouldRecordWatchHistory = false
    private struct WatchHistoryPlayback {
        let item: AVPlayerItem
        let report: WatchHistorySyncService.WatchTimeReporter
        var lastSample: TimeInterval?
    }
    private var watchHistoryPlayback: WatchHistoryPlayback?
    private var watchHistoryTimeJumpObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var itemErrorLogObservation: NSObjectProtocol?
    private var playerErrorObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?
    init(
        queue: QueueManager? = nil,
        preferences: UserPreferences? = nil
    ) {
        self.queue = queue ?? QueueManager()
        self.preferences = preferences ?? UserPreferences()
        // Keep the audio track running when the player view goes off-screen (popup minimize, app
        // backgrounded). Without this, AVPlayer pauses video tracks as soon as their pixel buffer
        // pipeline is no longer visible, which manifests as "audio cuts out the moment you collapse
        // the mini-player." Pairs with the `.playback` AVAudioSession configured at launch.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Restore the last-used playback speed. `defaultRate` is what `AVPlayerViewController`'s
        // speed menu writes, and `AVPlayer.play()` resumes at this rate (not the transient `rate`).
        // Setting it *before* installObservers keeps the KVO from firing back and re-saving the
        // same value during launch.
        player.defaultRate = Float(self.preferences.playbackRate)
        installObservers()
    }

    /// Tear-down hook for tests / app lifecycle. Call before releasing the manager. We avoid `deinit`
    /// here so we don't have to reach into main-actor-isolated state from a nonisolated context.
    func tearDownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let watchHistoryTimeJumpObserver { NotificationCenter.default.removeObserver(watchHistoryTimeJumpObserver) }
        timeObserver = nil
        endObserver = nil
        watchHistoryTimeJumpObserver = nil
        watchHistoryPlayback = nil
        presentationSizeObservation?.invalidate()
    }

    // MARK: - Public commands

    /// Play an already downloaded From URL file using its explicit path.
    /// Synthetic video metadata still drives the player and Now Playing controls.
    func loadLocalFile(at fileURL: URL, title: String, source: String?, thumbnailURL: URL?) {
        log.info("loadLocalFile path=\(fileURL.path, privacy: .public) title=\"\(title, privacy: .public)\"")
        playbackResolutionTask?.cancel()
        playbackResolutionTask = nil
        resetStreamResolution()
        if isPlaying { pause() }
        if !player.items().isEmpty { player.removeAllItems() }

        // Synthetic Video so the existing mini-player + FullScreenPlayer chrome (which read
        // `currentVideo` everywhere) work without conditional branches. Channel name reuses
        // the extractor ("YouTube", "Vimeo", …) — closest analogue for arbitrary URLs.
        let synthetic = Video(
            id: "fetch-" + UUID().uuidString,
            title: title,
            channelID: "",
            channelName: source ?? "Link",
            channelThumbnailURL: nil,
            thumbnailURL: thumbnailURL,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        currentVideo = synthetic
        isFromURLFile = true
        // Bypass the queue's YouTube-related tracking — URL files don't participate in the
        // recommendation chain. setCurrent appends to the queue dataset for upcoming-up UI;
        // we just zero it for arbitrary files.
        queueAcceptsRecommendations = false
        miniPlayerVisible = true
        elapsed = 0
        duration = 0
        refreshArtwork(for: synthetic)

        let item = AVPlayerItem(url: fileURL)
        loadItem(item)
        loadState = .readyToPlay
        updateNowPlaying()
        play()
    }

    /// Loads a YouTube video. Playlist batch callers can suppress recommendations to keep their queue.
    func load(_ video: Video, autoplay: Bool = true, skipRecommendations: Bool = false) {
        log.info("load(\(video.id, privacy: .public)) autoplay=\(autoplay, privacy: .public) skipRecs=\(skipRecommendations, privacy: .public)")
        queueAcceptsRecommendations = !skipRecommendations
        playbackResolutionTask?.cancel()
        resetStreamResolution()
        // Stop the previous video while the selected video's playback URL resolves.
        if isPlaying {
            log.info("load: pausing current playback before resolving new video")
            pause()
        }
        if !player.items().isEmpty {
            log.debug("load: clearing AVQueuePlayer items (\(self.player.items().count, privacy: .public) entries)")
            player.removeAllItems()
        }
        currentVideo = video
        isFromURLFile = false
        // Keep the queue coherent. Fresh taps from search/home append the video; subsequent calls
        // from `playNext()` / `playPrevious()` find it already there and just update `currentIndex`.
        queue.setCurrent(video)
        miniPlayerVisible = true
        loadState = .resolving
        // Wipe transport state from the previous video so a stray time-observer tick during the
        // transition (the periodic callback can fire AFTER currentVideo flips but BEFORE the new
        // AVPlayerItem is installed) doesn't carry the old item's elapsed/duration into a save —
        // that's what showed phantom progress bars on cells the user never played.
        elapsed = 0
        duration = 0
        refreshArtwork(for: video)
        playbackResolutionTask = Task { [weak self] in
            await self?.resolveAndPlay(video: video, autoplay: autoplay, skipRecommendations: skipRecommendations)
        }
    }

    /// Records playback locally and reports it to YouTube when synchronization is enabled.
    private func recordWatchHistory(video: Video, item: AVPlayerItem) {
        let videoID = video.id
        let title = video.title
        let channelName = video.channelName
        let thumbnailURL = video.thumbnailURL
        Task {
            await PersistenceWriter.shared.upsertWatchHistory(
                videoID: videoID,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL
            )
        }
        if let report = WatchHistorySyncService.shared.beginPlayback(videoID: videoID) {
            let startTime = item.currentTime().seconds
            watchHistoryPlayback = WatchHistoryPlayback(
                item: item,
                report: report,
                lastSample: startTime.isFinite && startTime >= 0 ? startTime : nil
            )
        }
    }

    private func sampleWatchHistory(at time: TimeInterval) {
        guard let playback = watchHistoryPlayback,
              playback.item === player.currentItem,
              player.timeControlStatus == .playing,
              time.isFinite, time >= 0 else { return }

        watchHistoryPlayback?.lastSample = time
        guard let previous = playback.lastSample else { return }
        let delta = time - previous
        // Samples normally arrive every 0.5 media seconds. Keep jumps out of the reported range.
        guard delta > 0, delta <= 1.25 else { return }
        watchHistoryPlayback = nil
        playback.report(previous...time)
    }

    func play() {
        log.info("play()")
        player.play()
        isPlaying = true
    }

    func pause() {
        log.info("pause()")
        watchHistoryPlayback?.lastSample = nil
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        log.info("togglePlayPause() (isPlaying=\(self.isPlaying, privacy: .public))")
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        watchHistoryPlayback?.lastSample = nil
        log.info("seek(to: \(seconds, privacy: .public)s)")
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekRelative(by delta: TimeInterval) {
        log.info("seekRelative(by: \(delta, privacy: .public)s)")
        seek(to: max(0, min(elapsed + delta, duration)))
    }

    func changeStreamResolution(to resolution: Int?) {
        let options = streamResolutionOptions
        guard !options.isEmpty, resolution != selectedStreamResolution,
              resolution.map(options.contains) ?? true, let item = player.currentItem else { return }

        let quality = DownloadManager.shared.currentDownloadQuality
        if let resolution, activeHLSPlayback?.resolution == resolution {
            selectedStreamResolution = resolution
            return
        }

        let candidates = fixedStreamCandidates.filter { candidate in
            if let resolution { return candidate.resolution == resolution }
            return quality.heightCap.map { (candidate.height ?? Int.max) <= $0 } ?? true
        }
        guard activeHLSPlayback != nil || !candidates.isEmpty else {
            resolutionChangeFailed = true
            return
        }
        if (item.asset as? AVURLAsset)?.url == candidates.first?.url {
            selectedStreamResolution = resolution
            return
        }
        isChangingResolution = true
        resolutionChangeTask = Task { [weak self] in
            await self?.switchStream(candidates, quality: quality, resolution: resolution, from: item)
        }
    }

    func playNext() {
        log.info("playNext() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        if let next = queue.advance() {
            load(next)
            return
        }
        // Queue at end. If this queue accepts recommendations and the user hasn't asked for
        // repeat-all/repeat-one, refill from the last item's recommendations and try advancing
        // again — that's the "endless queue" behavior: every time we hit the bottom, more recs
        // refill behind us.
        guard queueAcceptsRecommendations,
              queue.repeatMode == .off,
              let seed = queue.items.last else {
            log.notice("playNext: queue at end, no recs refill (acceptsRecs=\(self.queueAcceptsRecommendations, privacy: .public), repeat=\(String(describing: self.queue.repeatMode), privacy: .public))")
            return
        }
        log.info("playNext: queue at end, refilling recs from seed=\(seed.id, privacy: .public)")
        let currentVideoID = currentVideo?.id
        Task { [weak self] in
            guard let self, self.currentVideo?.id == currentVideoID else { return }
            let countBefore = self.queue.items.count
            await self.fillQueueWithRecommendations(for: seed)
            guard self.currentVideo?.id == currentVideoID else { return }
            guard self.queue.items.count > countBefore else {
                self.log.notice("playNext: refill produced no new items, giving up")
                return
            }
            if let next = self.queue.advance() {
                self.load(next)
            }
        }
    }

    func playPrevious() {
        log.info("playPrevious() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        guard let previous = queue.previous() else {
            log.notice("playPrevious: at start of queue, nothing to go back to")
            return
        }
        load(previous)
    }

    func dismiss() {
        log.info("dismiss()")
        playbackResolutionTask?.cancel()
        playbackResolutionTask = nil
        resetStreamResolution()
        pause()
        miniPlayerVisible = false
        fullScreenPresented = false
        currentVideo = nil
        loadState = .idle
        watchHistoryPlayback = nil
        player.removeAllItems()
        NowPlayingCenter.clear()
    }

    // MARK: - Internals

    private func resetStreamResolution() {
        resolutionChangeTask?.cancel()
        resolutionChangeTask = nil
        hlsPlaylistTask?.cancel()
        hlsPlaylistTask = nil
        isChangingResolution = false
        activeStreamKind = nil
        activeHLSPlayback = nil
        fixedStreamCandidates = []
        playbackResolution = nil
        selectedStreamResolution = nil
        resolutionChangeFailed = false
    }

    private func switchStream(
        _ candidates: [StreamCandidate], quality: VideoQuality, resolution: Int?, from previousItem: AVPlayerItem
    ) async {
        defer {
            if !Task.isCancelled {
                isChangingResolution = false
                resolutionChangeTask = nil
            }
        }
        guard !Task.isCancelled, player.currentItem === previousItem else { return }
        let position = previousItem.currentTime()
        let isLive = currentVideo?.isLive == true
        let programDate = isLive ? previousItem.currentDate() : nil
        let seekTime = !isLive && position.isNumeric && position.seconds > 0 ? position : nil
        func restorePosition() async -> Bool {
            if let programDate { return await player.seek(to: programDate) }
            if let seekTime { return await player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) }
            return true
        }

        let shouldResume = player.timeControlStatus != .paused
        let previousKind = activeStreamKind
        let previousHLS = activeHLSPlayback
        let previousMediaSelection = previousItem.currentMediaSelection
        let previousHistory = watchHistoryPlayback
        let recordHistoryOnPlay = shouldRecordWatchHistory
        pause()
        loadState = .resolving

        var switched: Bool
        if let previousHLS {
            switched = await tryHLSStream(
                previousHLS.candidate, maxHeight: quality.heightCap, preferHighest: quality == .highest,
                exactResolution: resolution, cachedPlaylist: previousHLS.playlist
            )
        } else {
            var attempted: Set<URL> = []
            switched = await tryStreams(candidates, maxHeight: nil, attempted: &attempted, limit: 3)
        }
        guard !Task.isCancelled else { return }
        if switched { switched = await restorePosition() }
        guard !Task.isCancelled else { return }
        if switched, previousHLS != nil, let item = player.currentItem {
            await restoreMediaSelection(previousMediaSelection, from: previousItem.asset, to: item)
        }
        guard !Task.isCancelled else { return }
        if switched {
            selectedStreamResolution = resolution
        } else {
            if player.currentItem !== previousItem { loadItem(previousItem) }
            activateStream(previousKind, hls: previousHLS)
            loadState = .readyToPlay
            _ = await restorePosition()
        }
        guard !Task.isCancelled else { return }
        if let item = player.currentItem, let previousHistory {
            watchHistoryPlayback = WatchHistoryPlayback(item: item, report: previousHistory.report, lastSample: nil)
        }
        shouldRecordWatchHistory = recordHistoryOnPlay

        if shouldResume { play() }
        resolutionChangeFailed = !switched
    }

    private func restoreMediaSelection(_ selection: AVMediaSelection, from original: AVAsset, to item: AVPlayerItem) async {
        for characteristic: AVMediaCharacteristic in [.audible, .legible] {
            guard let previousGroup = try? await original.loadMediaSelectionGroup(for: characteristic),
                  let nextGroup = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            guard !Task.isCancelled, player.currentItem === item else { return }
            if let option = selection.selectedMediaOption(in: previousGroup) {
                let match = nextGroup.mediaSelectionOption(withPropertyList: option.propertyList()) ?? nextGroup.options.first {
                    $0.extendedLanguageTag == option.extendedLanguageTag && $0.displayName == option.displayName
                }
                if let match { item.select(match, in: nextGroup) }
            } else if nextGroup.allowsEmptySelection {
                item.select(nil, in: nextGroup)
            }
        }
    }

    /// Swap the player to a new item using the `AVQueuePlayer`-correct pattern. `replaceCurrentItem`
    /// is documented to be a no-op when the player's internal queue is empty (which is our usual
    /// state since the playable URL is short-lived and we never preload), so we always tear the
    /// queue down to nothing first and then insert. Also wires KVO so we hear about decode/auth
    /// failures the moment they happen (CoreMedia's `CFByteFlume err=-12939` style messages don't
    /// surface a structured `NSError` otherwise).
    private func loadItem(_ item: AVPlayerItem, isStreamCandidate: Bool = false) {
        watchHistoryPlayback = nil
        playbackResolution = nil
        player.removeAllItems()
        shouldRecordWatchHistory = !isFromURLFile
        player.insert(item, after: nil)
        log.debug("loadItem: queue size after insert=\(self.player.items().count, privacy: .public)")
        observe(item: item, isStreamCandidate: isStreamCandidate)
    }

    private func observe(item: AVPlayerItem, isStreamCandidate: Bool) {
        itemStatusObservation?.invalidate()
        presentationSizeObservation?.invalidate()
        if let token = itemErrorLogObservation { NotificationCenter.default.removeObserver(token) }

        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.player.currentItem === item else { return }
                let size = item.presentationSize
                let dimension = min(size.width, size.height)
                let resolution = dimension > 0 ? Int(exactly: dimension.rounded()) : nil
                if self.playbackResolution != resolution {
                    self.playbackResolution = resolution
                    if let resolution { self.log.info("Playback resolution changed to \(resolution, privacy: .public)p") }
                }
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.player.currentItem === item else { return }
                switch item.status {
                case .unknown:
                    self.log.info("AVPlayerItem status: unknown")
                case .readyToPlay:
                    if !isStreamCandidate { self.loadState = .readyToPlay }
                    self.log.info("AVPlayerItem status: readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
                case .failed:
                    let error = item.error ?? YouTubeServiceError.streamExtractionFailed
                    if !isStreamCandidate || self.loadState == .readyToPlay {
                        self.loadState = .failed(ErrorState(from: error).message)
                    }
                    let details = error as NSError
                    self.log.error("AVPlayerItem status: FAILED domain=\(details.domain, privacy: .public) code=\(details.code, privacy: .public)")
                @unknown default:
                    break
                }
            }
        }

        itemErrorLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [log, weak item] _ in
            guard let item else { return }
            Task {
                guard let entry = await item.errorLog?.events.last else { return }
                log.error("AVPlayerItem error-log: domain=\(entry.errorDomain, privacy: .public) code=\(entry.errorStatusCode, privacy: .public)")
            }
        }
    }

    private func resolveAndPlay(video: Video, autoplay: Bool, skipRecommendations: Bool) async {
        guard !Task.isCancelled else { return }
        if let localFile = DownloadManager.shared.localFile(for: video.id) {
            loadItem(AVPlayerItem(url: localFile))
        } else {
            let started = await startStreaming(videoID: video.id)
            guard !Task.isCancelled else { return }
            guard started else {
                loadState = .failed(ErrorState(from: YouTubeServiceError.streamExtractionFailed).message)
                return
            }
        }

        updateNowPlaying()
        if autoplay { play() }
        if !skipRecommendations {
            await fillQueueWithRecommendations(for: video)
        }
    }

    private func startStreaming(videoID: String) async -> Bool {
        let quality = DownloadManager.shared.currentDownloadQuality
        log.info("Resolving stream quality=\(quality.rawValue, privacy: .public)")
        if quality == .highest { return await startHighestStream(videoID: videoID) }

        let maxHeight = quality.heightCap
        var attempted: Set<URL> = []
        var fixedStreams: [StreamCandidate] = []

        for source in StreamSource.allCases {
            guard !Task.isCancelled else { return false }
            let candidates = await streamCandidates(videoID: videoID, source: source)
            fixedStreams.append(contentsOf: candidates.filter { $0.kind != .hlsMaster })
            let masters = candidates.filter { $0.kind == .hlsMaster }
            let limit = source == .ytDlp || source == .ytDlpVisionOS ? 2 : 1
            if await tryStreams(masters, maxHeight: maxHeight, attempted: &attempted, limit: limit) {
                return true
            }
        }

        guard !Task.isCancelled else { return false }
        fixedStreamCandidates = fixedStreams.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        let eligible = fixedStreamCandidates.filter { candidate in
            maxHeight.map { (candidate.height ?? Int.max) <= $0 } ?? true
        }
        return await tryStreams(eligible, maxHeight: maxHeight, attempted: &attempted, limit: 3)
    }

    private func streamCandidates(videoID: String, source: StreamSource) async -> [StreamCandidate] {
        let service = VideoService()
        switch source {
        case .ios:
            guard let info = try? await service.fetchInfo(id: videoID) else { return [] }
            return Self.nativeStreams(info, formats: info.formats, source: source)
        case .tv:
            guard let info = try? await service.fetchInfoViaTVHTML5(id: videoID) else { return [] }
            return Self.nativeStreams(info, formats: info.formats, source: source)
        case .formats:
            guard let result = try? await service.fetchInfoWithFormats(id: videoID) else { return [] }
            return Self.nativeStreams(result.info, formats: result.formats, source: source)
        case .ytDlpVisionOS, .ytDlp:
            do {
                let media = try await YtDlpInfoService().probe(
                    url: "https://www.youtube.com/watch?v=\(videoID)", useVisionOSClient: source == .ytDlpVisionOS
                )
                let candidates = Self.probedStreams(from: media.formats, source: source)
                if candidates.isEmpty, !Task.isCancelled {
                    log.notice("\(source.rawValue, privacy: .public) found no compatible stream for \(videoID, privacy: .public)")
                }
                return candidates
            } catch {
                if !Task.isCancelled {
                    log.notice("\(source.rawValue, privacy: .public) playback probe failed for \(videoID, privacy: .public)")
                }
                return []
            }
        }
    }

    private func startHighestStream(videoID: String) async -> Bool {
        let sources = StreamSource.allCases
        let (results, continuation) = AsyncStream<(StreamSource?, [StreamCandidate])>.makeStream()
        let lookups = sources.filter { $0 != .ytDlp }.map { source in
            Task { @MainActor in
                let candidates = await self.inspectStreamCandidates(videoID: videoID, source: source)
                guard !Task.isCancelled else { return }
                continuation.yield((source, candidates))
                if source == .ytDlpVisionOS {
                    let fallback = candidates.contains { $0.kind == .hlsMaster }
                        ? [] : await self.inspectStreamCandidates(videoID: videoID, source: .ytDlp)
                    guard !Task.isCancelled else { return }
                    continuation.yield((.ytDlp, fallback))
                }
            }
        }
        let comparisonDeadline = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { continuation.yield((nil, [])) }
        }
        defer {
            comparisonDeadline.cancel()
            for lookup in lookups { lookup.cancel() }
            continuation.finish()
        }

        var iterator = results.makeAsyncIterator()
        var received: [StreamSource: [StreamCandidate]] = [:]
        var attempted: Set<URL> = []
        var comparisonExpired = false
        // Start comparing after five seconds if any candidates are ready. The yt-dlp probe
        // shares a worker with downloads, so it may still be waiting by then.
        while received.count < sources.count, let (source, candidates) = await iterator.next() {
            if let source {
                received[source] = candidates
            } else {
                comparisonExpired = true
            }
            if comparisonExpired, received.values.contains(where: { !$0.isEmpty }) { break }
        }

        while !Task.isCancelled {
            let ranked = sources.flatMap { received[$0] ?? [] }.sorted { lhs, rhs in
                let lhsResolution = lhs.manifestResolutions.last ?? lhs.resolution ?? 0
                let rhsResolution = rhs.manifestResolutions.last ?? rhs.resolution ?? 0
                if lhsResolution != rhsResolution { return lhsResolution > rhsResolution }
                return lhs.kind == .hlsMaster && rhs.kind != .hlsMaster
            }
            fixedStreamCandidates = ranked.filter { $0.kind != .hlsMaster }
            if await tryStreams(ranked, maxHeight: nil, attempted: &attempted, limit: 8 - attempted.count, preferHighestHLS: true) {
                return true
            }
            guard attempted.count < 8, received.count < sources.count,
                  let (source, candidates) = await iterator.next() else { break }
            if let source { received[source] = candidates }
        }

        // An advertised visionOS playlist can still fail preparation on this device.
        guard !Task.isCancelled, received[.ytDlpVisionOS]?.contains(where: { $0.kind == .hlsMaster }) == true else { return false }
        let fallback = await inspectStreamCandidates(videoID: videoID, source: .ytDlp)
        guard !Task.isCancelled else { return false }
        fixedStreamCandidates.append(contentsOf: fallback.filter { $0.kind != .hlsMaster })
        fixedStreamCandidates.sort { ($0.resolution ?? 0) > ($1.resolution ?? 0) }
        return await tryStreams(fallback, maxHeight: nil, attempted: &attempted, limit: 3, preferHighestHLS: true)
    }

    private func inspectStreamCandidates(videoID: String, source: StreamSource) async -> [StreamCandidate] {
        var candidates = await streamCandidates(videoID: videoID, source: source)
        for index in candidates.indices where candidates[index].kind == .hlsMaster {
            guard !Task.isCancelled else { return [] }
            if candidates[index].manifestResolutions.isEmpty {
                candidates[index].manifestResolutions = await hlsResolutions(at: candidates[index].url)
            }
            let label = candidates[index].manifestResolutions.map { "\($0)p" }.joined(separator: ", ")
            log.info("HLS resolutions from \(source.rawValue, privacy: .public): \(label.isEmpty ? "unknown" : label, privacy: .public)")
        }
        return candidates
    }

    private func hlsResolutions(at url: URL) async -> [Int] {
        let asset = AVURLAsset(url: url)
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { asset.cancelLoading() }
        }
        defer { deadline.cancel() }
        guard let variants = try? await asset.load(.variants) else { return [] }
        let resolutions = variants.compactMap { variant -> Int? in
            guard let size = variant.videoAttributes?.presentationSize else { return nil }
            let dimension = min(size.width, size.height)
            return dimension > 0 ? Int(exactly: dimension.rounded()) : nil
        }
        return Set(resolutions).sorted()
    }

    private func applyStreamLimit(_ resolution: Int?, to item: AVPlayerItem) {
        guard let resolution else {
            item.preferredMaximumResolution = .zero
            return
        }
        // Allow standard 16:9 and wider cinema variants at the selected resolution.
        item.preferredMaximumResolution = CGSize(width: resolution * 2, height: resolution)
    }

    private func tryStreams(
        _ candidates: [StreamCandidate], maxHeight: Int?, attempted: inout Set<URL>, limit: Int, preferHighestHLS: Bool = false
    ) async -> Bool {
        var remaining = limit
        for candidate in candidates {
            guard remaining > 0, !Task.isCancelled else { return false }
            guard attempted.insert(candidate.url).inserted else { continue }
            remaining -= 1

            if candidate.kind == .hlsMaster {
                if await tryHLSStream(candidate, maxHeight: maxHeight, preferHighest: preferHighestHLS) { return true }
            } else if await prepareStream(AVPlayerItem(url: candidate.url), label: streamLabel(candidate)) {
                activateStream(candidate.kind)
                loadState = .readyToPlay
                return true
            }
        }
        return false
    }

    private func tryHLSStream(
        _ candidate: StreamCandidate, maxHeight: Int?, preferHighest: Bool,
        exactResolution: Int? = nil, cachedPlaylist: HLSResolutionPlaylist? = nil
    ) async -> Bool {
        var playlist = cachedPlaylist
        if playlist == nil, preferHighest || exactResolution != nil {
            playlist = try? await HLSResolutionPlaylist.load(from: candidate.url)
        }
        guard !Task.isCancelled else { return false }

        let label = streamLabel(candidate)
        if let playlist {
            let attempts = exactResolution.map { [$0] } ?? (preferHighest ? Array(playlist.resolutions.prefix(3)) : [])
            for resolution in attempts {
                guard !Task.isCancelled else { return false }
                guard let playback = playlist.makePlayback(resolution: resolution) else { continue }
                let item = AVPlayerItem(asset: playback.asset)
                let timeout: Duration = exactResolution == nil ? .seconds(4) : .seconds(8)
                guard await prepareStream(item, label: "\(label) selected=\(resolution)p", expectedResolution: resolution, timeout: timeout) else { continue }
                activateStream(.hlsMaster, hls: HLSPlayback(candidate: candidate, playlist: playlist, loader: playback.loader, resolution: resolution))
                loadState = .readyToPlay
                return true
            }
        }

        guard exactResolution == nil, !Task.isCancelled else { return false }
        let item = AVPlayerItem(url: candidate.url)
        applyStreamLimit(maxHeight, to: item)
        guard await prepareStream(item, label: "\(label) adaptive") else { return false }
        activateStream(.hlsMaster, hls: HLSPlayback(candidate: candidate, playlist: playlist, loader: nil, resolution: nil))
        loadState = .readyToPlay
        return true
    }

    private func activateStream(_ kind: StreamCandidate.Kind?, hls: HLSPlayback? = nil) {
        hlsPlaylistTask?.cancel()
        hlsPlaylistTask = nil
        activeStreamKind = kind
        activeHLSPlayback = hls
        guard let hls, hls.playlist == nil, hls.resolutions.isEmpty, let item = player.currentItem else { return }

        let url = hls.candidate.url
        hlsPlaylistTask = Task { [weak self, weak item] in
            let playlist = try? await HLSResolutionPlaylist.load(from: url)
            guard !Task.isCancelled, let self, let item, self.player.currentItem === item else { return }
            self.activeHLSPlayback?.playlist = playlist
            self.hlsPlaylistTask = nil
        }
    }

    private func streamLabel(_ candidate: StreamCandidate) -> String {
        let offered = (candidate.manifestResolutions.last ?? candidate.resolution).map { "\($0)p" } ?? "unknown"
        return "\(candidate.source.rawValue) \(candidate.kind.rawValue) format=\(candidate.formatID) offeredMax=\(offered)"
    }

    /// Wait for preparation before requesting playback so a timed-out item cannot write to history.
    private func prepareStream(
        _ item: AVPlayerItem, label: String, expectedResolution: Int? = nil, timeout: Duration = .seconds(8)
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        log.info("Trying stream: \(label, privacy: .public)")
        loadItem(item, isStreamCandidate: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled, player.currentItem === item, item.status == .unknown, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard !Task.isCancelled else { return false }
        if player.currentItem === item, item.status == .readyToPlay {
            let size = item.presentationSize
            let shortSide = min(size.width, size.height)
            if let expectedResolution, shortSide > 0, abs(shortSide - CGFloat(expectedResolution)) > 16 {
                log.notice("Stream resolution mismatch: \(label, privacy: .public) rendered=\(shortSide, privacy: .public)p")
                player.removeAllItems()
                return false
            }
            log.info("Stream ready: \(label, privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
            return true
        }

        if let error = item.error as NSError? {
            log.notice("Stream failed: \(label, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
        } else if player.currentItem === item, item.status == .unknown {
            log.notice("Stream preparation timed out: \(label, privacy: .public)")
        } else {
            log.notice("Stream item became unavailable: \(label, privacy: .public)")
        }
        if player.currentItem === item { player.removeAllItems() }
        return false
    }

    private static func nativeStreams(_ info: VideoInfo, formats: [VideoFormat], source: StreamSource) -> [StreamCandidate] {
        let manifest = info.streamingURL.map {
            StreamCandidate(url: $0, source: source, formatID: "manifest", kind: .hlsMaster, height: nil, width: nil)
        }
        let progressive = formats.filter {
            $0.containsBothTracks && $0.url != nil && $0.mimeType.lowercased().contains("mp4")
        }
        .compactMap { format in
            format.url.map { StreamCandidate(url: $0, source: source, formatID: format.id, kind: .mp4, height: format.height, width: format.width) }
        }
        return [manifest].compactMap { $0 } + progressive
    }

    private static func probedStreams(from formats: [RemoteFormat], source: StreamSource) -> [StreamCandidate] {
        let playable = formats.filter {
            $0.url?.scheme?.lowercased() == "https" && $0.url?.host != nil
        }
        .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        let hlsFormats = playable.filter { $0.protocolKind == .hls }
        let manifestsWithAudio = Set(hlsFormats.filter { $0.hasAudio || $0.isHLSAudioRendition }.compactMap(\.manifestURL))
        let videoByManifest = Dictionary(grouping: hlsFormats.filter(\.hasVideo), by: \.manifestURL)
        var seenManifests: Set<URL> = []
        let masters = hlsFormats.compactMap { format -> StreamCandidate? in
            guard format.hasVideo, let url = format.manifestURL,
                  url.scheme?.lowercased() == "https", url.host != nil,
                  manifestsWithAudio.contains(url), seenManifests.insert(url).inserted else { return nil }
            let resolutions = videoByManifest[url, default: []].compactMap { variant -> Int? in
                guard let height = variant.height else { return nil }
                return min(variant.width ?? height, height)
            }
            return StreamCandidate(
                url: url, source: source, formatID: format.id, kind: .hlsMaster, height: nil, width: nil,
                manifestResolutions: Set(resolutions.filter { $0 > 0 }).sorted()
            )
        }
        let hls = masters + hlsFormats.filter { $0.isProgressive }.compactMap { format in
            format.url.map { StreamCandidate(url: $0, source: source, formatID: format.id, kind: .hls, height: format.height, width: format.width) }
        }
        let mp4 = playable.filter {
            $0.isProgressive && $0.protocolKind == .https && $0.ext.lowercased() == "mp4"
                && ($0.vcodec?.lowercased().hasPrefix("avc1") == true || $0.vcodec?.lowercased() == "h264")
                && ($0.acodec?.lowercased().hasPrefix("mp4a") == true || $0.acodec?.lowercased() == "aac")
        }
        .compactMap { format in
            format.url.map { StreamCandidate(url: $0, source: source, formatID: format.id, kind: .mp4, height: format.height, width: format.width) }
        }
        return hls + mp4
    }

    /// Fetches `MoreVideoInfosResponse` for the current video and appends the recommended videos to
    /// the queue. This is what makes the player behave like the YouTube app: tap any video and a
    /// fresh "up next" queue is ready to advance when the current track ends.
    private func fillQueueWithRecommendations(for seed: Video) async {
        guard let currentVideoID = currentVideo?.id else { return }
        do {
            let info = try await VideoService().fetchMoreInfo(id: seed.id)
            guard !Task.isCancelled, currentVideo?.id == currentVideoID else { return }
            // Only append recommendations that aren't already queued, preserving the user's own
            // ordering if they came from a "Play all" playlist load.
            let existingIDs = Set(queue.items.map(\.id))
            let toAppend = info.recommended.filter { !existingIDs.contains($0.id) }
            for rec in toAppend {
                queue.append(rec)
            }
            log.info("Queued \(toAppend.count, privacy: .public) recommendations for \(seed.id, privacy: .public)")
        } catch {
            log.notice("Recommendation fetch failed for \(seed.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func installObservers() {
        // Periodic time observation via Combine-friendly bridging.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated { self.sampleWatchHistory(at: time.seconds) }
            Task { @MainActor in
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite { self.duration = total }
                }
                self.updateNowPlaying()
            }
        }

        watchHistoryTimeJumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, self.watchHistoryPlayback?.item === item else { return }
                self.watchHistoryPlayback?.lastSample = nil
            }
        }

        // Auto-advance on item end.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let item = notification.object as? AVPlayerItem {
                MainActor.assumeIsolated {
                    if self.watchHistoryPlayback?.item === item { self.watchHistoryPlayback = nil }
                }
            }
            Task { @MainActor in
                if self.preferences.autoplayNext { self.playNext() }
            }
        }

        // Mirror AVPlayer's transport state into our `isPlaying` flag so the custom transport row
        // under the video title (and the popup-bar play/pause glyph) reflects taps on the native
        // AVPlayerViewController controls. Without this, hitting the native pause button on the
        // video surface left our SwiftUI button showing "Pause" forever.
        // Persist user-driven speed changes from AVPlayerViewController's built-in speed menu.
        // The menu writes to `defaultRate`; KVO catches the write and we save it to prefs so the
        // next app launch starts at the same speed.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let newValue = change.newValue else { return }
            let rate = Double(newValue)
            // Sanity: defaultRate of 0 would mean "paused on play()" which YouTube/AVPlayerViewController
            // never offers as a user option. Ignore any such bogus write.
            guard rate > 0 else { return }
            Task { @MainActor in
                if abs(rate - self.preferences.playbackRate) > 0.001 {
                    self.log.info("playbackRate changed → \(rate, privacy: .public) (persisting)")
                    self.preferences.playbackRate = rate
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            let playingItem = status == .playing ? avPlayer.currentItem : nil
            Task { @MainActor in
                switch status {
                case .playing:
                    // The callback may reach the main actor after a different video was selected.
                    if self.shouldRecordWatchHistory,
                       let playingItem,
                       playingItem === self.player.currentItem,
                       let video = self.currentVideo {
                        self.shouldRecordWatchHistory = false
                        self.recordWatchHistory(video: video, item: playingItem)
                    }
                    if !self.isPlaying {
                        self.log.info("KVO timeControlStatus → playing (sync isPlaying=true)")
                        self.isPlaying = true
                    }
                case .paused:
                    if self.player.timeControlStatus == .paused { self.watchHistoryPlayback?.lastSample = nil }
                    if self.isPlaying {
                        self.log.info("KVO timeControlStatus → paused (sync isPlaying=false)")
                        self.isPlaying = false
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering / stalled. Treat as "playing" so the UI still shows pause icon,
                    // matching what the native AVPlayerViewController shows.
                    if !self.isPlaying {
                        self.isPlaying = true
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let video = currentVideo else { return }
        NowPlayingCenter.update(
            title: video.title,
            artist: video.channelName,
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? 1.0 : 0.0,
            artwork: currentArtwork
        )
    }

    /// Resolves an artwork image for the given video and stores it in `currentArtwork`. Tries three
    /// sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flicker).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the constructed `Video` has `thumbnailURL == nil`).
    ///  3. Async network/disk fetch through Kingfisher.
    /// Clears artwork immediately so the previous video's preview doesn't linger on the lock screen.
    private func refreshArtwork(for video: Video) {
        currentArtwork = nil

        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            currentArtwork = cached
            updateNowPlaying()
            return
        }

        // Xattr fallback for downloaded-only videos. `DownloadsStore.thumbnail(forVideoID:)`
        // is synchronous (the entries snapshot lives in memory) so we can decode + assign
        // inline rather than through a Task / background actor.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            currentArtwork = image
            updateNowPlaying()
        }

        // Async network/disk fetch as last resort.
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [weak self, videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Drop the result if the user switched videos while the fetch was inflight.
                guard self.currentVideo?.id == videoID else { return }
                self.currentArtwork = value.image
                self.updateNowPlaying()
            }
        }
    }
}
