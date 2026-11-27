import Foundation
import AVFoundation
import Combine
import Kingfisher
import OSLog
import SwiftData
import UIKit

enum PlaybackTrackKind {
    case audio
    case subtitle
}

struct PlaybackTrack: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
}

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

    enum YouTubeSubtitleListState {
        case idle
        case loading
        case ready
        case unavailable
        case failed
    }

    struct TrackMenu {
        let tracks: [PlaybackTrack]
        let allowsOff: Bool
        let select: (String?) -> Void
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
        var playlist: HLSResolutionPlaylist? = nil

        var resolution: Int? { height.map { min(width ?? $0, $0) } }
    }

    private struct HLSPlayback {
        let candidate: StreamCandidate
        var playlist: HLSResolutionPlaylist?
        let loader: HLSResolutionResourceLoader?
        let resolution: Int?

        var resolutions: [Int] { playlist?.resolutions ?? Array(candidate.manifestResolutions.reversed()) }
    }

    private struct VLCSource {
        let url: URL
        var playlistData: Data? = nil
        var resolution: Int? = nil
        var maximumResolution: Int? = nil
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
    private(set) var playbackSpeed: Float
    private(set) var isHoldingPlaybackBoost = false
    private(set) var playbackResolution: Int?
    private(set) var selectedStreamResolution: Int?
    private(set) var vlcPlayback: VLCKitPlayback?
    private(set) var stagedVLCPlayback: VLCKitPlayback?
    private(set) var isAirPlayMode = false
    private(set) var isExternalPlaybackActive = false
    private(set) var youtubeSubtitleTracks: [RemoteSubtitle] = []
    private(set) var youtubeSubtitleListState: YouTubeSubtitleListState = .idle
    private(set) var selectedYouTubeSubtitleID: String?
    private(set) var isLoadingYouTubeSubtitleTrack = false
    var youtubeSubtitleLoadFailed = false
    var canLoadYouTubeSubtitles: Bool {
        canChangePlaybackOptions && !isFromURLFile && !isAirPlayMode && currentVideo?.isLive == false
    }
    var youtubeSubtitleText: String? {
        guard canLoadYouTubeSubtitles, selectedYouTubeSubtitleID != nil else { return nil }
        return youtubeSubtitleCues.last { $0.start <= elapsed && elapsed < $0.end }?.text
    }
    var airPlayHandoffFailed = false
    var canUseAirPlay: Bool {
        loadState == .readyToPlay && !isChangingResolution && (isAirPlayMode || (vlcPlayback != nil && currentVLCSource != nil))
    }
    var resolutionChangeFailed = false
    var streamResolutionOptions: [Int] {
        guard loadState == .readyToPlay, activeStreamKind != nil, !isChangingResolution, !isAirPlayMode else { return [] }
        if let activeHLSPlayback { return activeHLSPlayback.resolutions }
        let resolutions = Set(fixedStreamCandidates.compactMap(\.resolution).filter { $0 > 0 })
        return resolutions.count > 1 ? resolutions.sorted(by: >) : []
    }
    var miniPlayerVisible: Bool = false
    var fullScreenPresented: Bool = false
    var canChangePlaybackOptions: Bool {
        loadState == .readyToPlay && !isChangingResolution && (vlcPlayback != nil || player.currentItem != nil)
    }

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
    private var isFinishingHandoff = false
    private var currentVLCSource: VLCSource?
    private var activeStreamKind: StreamCandidate.Kind?
    private var activeHLSPlayback: HLSPlayback?
    private var fixedStreamCandidates: [StreamCandidate] = []
    private var shouldRecordWatchHistory = false
    private struct WatchHistoryPlayback {
        let videoID: String
        var report: WatchHistorySyncService.WatchTimeReporter?
        var lastSample: TimeInterval?
        var unreportedStart: TimeInterval?
        var seekPosition: TimeInterval?
        var lastReport: (position: TimeInterval, state: WatchHistorySyncService.PlaybackState)?
    }
    private var watchHistoryPlayback: WatchHistoryPlayback?
    private var seekTask: Task<Void, Never>?
    private var finishWatchHistoryAfterSeek = false
    private var watchHistoryTimeJumpObserver: NSObjectProtocol?
    private var vlcTracks: [PlaybackTrackKind: [PlaybackTrack]] = [:]
    private var nativeTrackGroups: [PlaybackTrackKind: AVMediaSelectionGroup] = [:]
    private var nativeMediaSelection: AVMediaSelection?
    private var nativeMediaSelectionObserver: NSObjectProtocol?
    private var nativeTrackLoadTask: Task<Void, Never>?
    private var youtubeSubtitleListTask: Task<Void, Never>?
    private var youtubeSubtitleCueTask: Task<Void, Never>?
    private var youtubeSubtitleCues: [PlaybackSubtitleCue] = []
    private var timeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var itemErrorLogObservation: NSObjectProtocol?
    private var playerErrorObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    init(
        queue: QueueManager? = nil,
        preferences: UserPreferences? = nil
    ) {
        self.queue = queue ?? QueueManager()
        self.preferences = preferences ?? UserPreferences()
        let savedSpeed = Float(self.preferences.playbackRate)
        playbackSpeed = savedSpeed.isFinite && savedSpeed > 0 ? savedSpeed : 1
        // Keep the audio track running when the player view goes off-screen (popup minimize, app
        // backgrounded). Without this, AVPlayer pauses video tracks as soon as their pixel buffer
        // pipeline is no longer visible, which manifests as "audio cuts out the moment you collapse
        // the mini-player." Pairs with the `.playback` AVAudioSession configured at launch.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.allowsExternalPlayback = false
        // Restore the last-used playback speed. `defaultRate` is what `AVPlayerViewController`'s
        // speed menu writes, and `AVPlayer.play()` resumes at this rate (not the transient `rate`).
        // Setting it *before* installObservers keeps the KVO from firing back and re-saving the
        // same value during launch.
        player.defaultRate = playbackSpeed
        installObservers()
    }

    /// Tear-down hook for tests / app lifecycle. Call before releasing the manager. We avoid `deinit`
    /// here so we don't have to reach into main-actor-isolated state from a nonisolated context.
    func tearDownObservers() {
        resetStreamResolution()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let watchHistoryTimeJumpObserver { NotificationCenter.default.removeObserver(watchHistoryTimeJumpObserver) }
        if let nativeMediaSelectionObserver { NotificationCenter.default.removeObserver(nativeMediaSelectionObserver) }
        timeObserver = nil
        endObserver = nil
        watchHistoryTimeJumpObserver = nil
        nativeMediaSelectionObserver = nil
        presentationSizeObservation?.invalidate()
        externalPlaybackObservation?.invalidate()
    }

    // MARK: - Public commands

    func trackMenu(for kind: PlaybackTrackKind) -> TrackMenu? {
        guard canChangePlaybackOptions else { return nil }
        if let playback = vlcPlayback {
            guard let tracks = vlcTracks[kind], !tracks.isEmpty else { return nil }
            return TrackMenu(tracks: tracks, allowsOff: kind == .subtitle) { [weak self, weak playback] id in
                guard let self, let playback, self.vlcPlayback === playback, canChangePlaybackOptions else { return }
                if kind == .subtitle { clearYouTubeSubtitleSelection() }
                playback.selectTrack(id, for: kind)
            }
        }

        guard let item = player.currentItem, let group = nativeTrackGroups[kind] else { return nil }
        let options = group.options.filter(\.isPlayable)
        guard !options.isEmpty else { return nil }
        let selected = nativeMediaSelection?.selectedMediaOption(in: group)
        let tracks = options.enumerated().map { index, option in
            PlaybackTrack(id: String(index), title: option.displayName, isSelected: option == selected)
        }
        return TrackMenu(tracks: tracks, allowsOff: kind == .subtitle && group.allowsEmptySelection) { [weak self, weak item] id in
            guard let self, let item, player.currentItem === item, vlcPlayback == nil, canChangePlaybackOptions else { return }
            if let id {
                guard let index = Int(id), options.indices.contains(index) else { return }
                if kind == .subtitle { clearYouTubeSubtitleSelection() }
                item.select(options[index], in: group)
            } else if kind == .subtitle && group.allowsEmptySelection {
                clearYouTubeSubtitleSelection()
                item.select(nil, in: group)
            }
            nativeMediaSelection = item.currentMediaSelection
        }
    }

    func preloadYouTubeSubtitles() {
        guard fullScreenPresented, youtubeSubtitleListState == .idle else { return }
        findYouTubeSubtitles()
    }

    func findYouTubeSubtitles() {
        guard canLoadYouTubeSubtitles, let videoID = currentVideo?.id,
              youtubeSubtitleListState == .idle || youtubeSubtitleListState == .failed else { return }
        youtubeSubtitleListState = .loading
        youtubeSubtitleListTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let tracks = try? await YtDlpInfoService().youtubeSubtitles(videoID: videoID)
            guard !Task.isCancelled, let self else { return }
            youtubeSubtitleListTask = nil
            if let tracks {
                youtubeSubtitleTracks = tracks
                youtubeSubtitleListState = tracks.isEmpty ? .unavailable : .ready
            } else {
                youtubeSubtitleListState = .failed
            }
        }
    }

    func selectYouTubeSubtitle(_ id: String) {
        guard canLoadYouTubeSubtitles, !isLoadingYouTubeSubtitleTrack, selectedYouTubeSubtitleID != id,
              let track = youtubeSubtitleTracks.first(where: { $0.id == id }) else { return }
        isLoadingYouTubeSubtitleTrack = true
        youtubeSubtitleCueTask = Task { [weak self] in
            let cues = try? await YtDlpInfoService().loadSubtitleCues(for: track)
            guard !Task.isCancelled, let self else { return }
            isLoadingYouTubeSubtitleTrack = false
            youtubeSubtitleCueTask = nil
            if let cues {
                selectedYouTubeSubtitleID = track.id
                youtubeSubtitleCues = cues
                if !isAirPlayMode { disableStreamSubtitles() }
            } else {
                // The timed-text URL is temporary. Let the next attempt fetch fresh URLs.
                youtubeSubtitleTracks = []
                youtubeSubtitleListState = .failed
                youtubeSubtitleLoadFailed = true
            }
        }
    }

    func turnOffSubtitles() {
        guard canLoadYouTubeSubtitles else { return }
        clearYouTubeSubtitleSelection()
        disableStreamSubtitles()
    }

    private func clearYouTubeSubtitleSelection() {
        youtubeSubtitleCueTask?.cancel()
        youtubeSubtitleCueTask = nil
        isLoadingYouTubeSubtitleTrack = false
        selectedYouTubeSubtitleID = nil
        youtubeSubtitleCues = []
    }

    private func disableStreamSubtitles() {
        if let vlcPlayback, vlcTracks[.subtitle]?.contains(where: \.isSelected) == true {
            vlcPlayback.selectTrack(nil, for: .subtitle)
        } else if vlcPlayback == nil, let item = player.currentItem,
                  let group = nativeTrackGroups[.subtitle], group.allowsEmptySelection {
            item.select(nil, in: group)
            nativeMediaSelection = item.currentMediaSelection
        }
    }

    func changePlaybackSpeed(to speed: Float) {
        guard canChangePlaybackOptions, speed.isFinite, speed > 0 else { return }
        endPlaybackBoost()
        player.defaultRate = speed
        storePlaybackSpeed(speed)
        if vlcPlayback == nil, player.timeControlStatus != .paused {
            player.rate = speed
        }
    }

    func beginPlaybackBoost() {
        guard !isHoldingPlaybackBoost, fullScreenPresented, canChangePlaybackOptions,
              !isAirPlayMode, currentVideo?.isLive == false,
              vlcPlayback?.isPlaying ?? (player.timeControlStatus == .playing) else { return }

        isHoldingPlaybackBoost = true
        if let vlcPlayback {
            vlcPlayback.setPlaybackSpeed(2)
        } else {
            player.rate = 2
        }
    }

    func endPlaybackBoost() {
        guard isHoldingPlaybackBoost else { return }
        isHoldingPlaybackBoost = false
        if let vlcPlayback {
            vlcPlayback.setPlaybackSpeed(playbackSpeed)
        } else if player.currentItem != nil, player.timeControlStatus != .paused {
            player.rate = player.defaultRate
        }
    }

    private func storePlaybackSpeed(_ speed: Float) {
        guard speed != playbackSpeed else { return }
        playbackSpeed = speed
        preferences.playbackRate = Double(speed)
        vlcPlayback?.setPlaybackSpeed(speed)
    }

    /// Play an already downloaded From URL file using its explicit path.
    /// Synthetic video metadata still drives the player and Now Playing controls.
    func loadLocalFile(at fileURL: URL, title: String, source: String?, thumbnailURL: URL?) {
        log.info("loadLocalFile path=\(fileURL.path, privacy: .public) title=\"\(title, privacy: .public)\"")
        playbackResolutionTask?.cancel()
        playbackResolutionTask = nil
        resetStreamResolution(keepingAirPlay: isAirPlayMode)
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

        loadState = .resolving
        fullScreenPresented = true
        playbackResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveAndPlay(video: synthetic, fileURL: fileURL, autoplay: true, skipRecommendations: true)
        }
    }

    /// Loads a YouTube video and opens the player. Queue navigation can keep the current presentation.
    func load(
        _ video: Video,
        autoplay: Bool = true,
        skipRecommendations: Bool = false,
        startAt: TimeInterval = 0,
        expandPlayer: Bool = true
    ) {
        log.info("load(\(video.id, privacy: .public)) autoplay=\(autoplay, privacy: .public) skipRecs=\(skipRecommendations, privacy: .public) startAt=\(startAt, privacy: .public)s")
        queueAcceptsRecommendations = !skipRecommendations
        playbackResolutionTask?.cancel()
        resetStreamResolution(keepingAirPlay: isAirPlayMode)
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
        shouldRecordWatchHistory = true
        // Keep the queue coherent. Fresh taps from search/home append the video; subsequent calls
        // from `playNext()` / `playPrevious()` find it already there and just update `currentIndex`.
        queue.setCurrent(video)
        miniPlayerVisible = true
        loadState = .resolving
        if expandPlayer { fullScreenPresented = true }
        // Wipe transport state from the previous video so a stray time-observer tick during the
        // transition (the periodic callback can fire AFTER currentVideo flips but BEFORE the new
        // AVPlayerItem is installed) doesn't carry the old item's elapsed/duration into a save —
        // that's what showed phantom progress bars on cells the user never played.
        elapsed = 0
        duration = 0
        refreshArtwork(for: video)
        let position = !video.isLive && startAt.isFinite && startAt > 0
            && (video.duration.map { $0 <= 0 || startAt < $0 } ?? true) ? startAt : 0
        playbackResolutionTask = Task { [weak self] in
            await self?.resolveAndPlay(
                video: video, autoplay: autoplay, skipRecommendations: skipRecommendations, startAt: position
            )
        }
    }

    private func recordWatchHistoryIfNeeded(at time: TimeInterval) {
        guard shouldRecordWatchHistory, let video = currentVideo else { return }
        shouldRecordWatchHistory = false
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
        startWatchHistorySync(videoID: videoID, at: time)
    }

    private func startWatchHistorySync(videoID: String, at time: TimeInterval? = nil) {
        guard let report = WatchHistorySyncService.shared.beginPlayback(videoID: videoID) else {
            watchHistoryPlayback = nil
            return
        }
        watchHistoryPlayback = WatchHistoryPlayback(videoID: videoID, report: report)
        if let time { collectWatchHistorySample(at: time) }
    }

    private func resumeWatchHistorySyncIfNeeded(at time: TimeInterval) {
        guard let playback = watchHistoryPlayback, playback.videoID == currentVideo?.id,
              playback.report == nil else { return }
        startWatchHistorySync(videoID: playback.videoID, at: time)
    }

    private func sampleWatchHistory(at time: TimeInterval) {
        guard vlcPlayback?.isPlaying ?? (player.timeControlStatus == .playing) else { return }
        collectWatchHistorySample(at: time)
        guard let playback = watchHistoryPlayback, let start = playback.unreportedStart,
              let end = playback.lastSample else { return }
        // Send the first measured segment promptly, then batch up to 30 media seconds.
        if playback.lastReport == nil || end - start >= 30 {
            reportWatchHistory(.playing)
        }
    }

    private func collectWatchHistorySample(at time: TimeInterval) {
        guard seekTask == nil, let playback = watchHistoryPlayback, playback.report != nil,
              playback.videoID == currentVideo?.id,
              time.isFinite, time >= 0 else { return }
        if let previous = playback.lastSample {
            let delta = time - previous
            if delta < 0 || delta > 1.25 {
                // Close the existing segment before starting again across a clock jump.
                reportWatchHistory(.playing)
            } else if delta > 0, playback.unreportedStart == nil {
                watchHistoryPlayback?.unreportedStart = previous
            }
        }
        watchHistoryPlayback?.lastSample = time
    }

    private func reportWatchHistory(_ state: WatchHistorySyncService.PlaybackState) {
        guard let playback = watchHistoryPlayback, let report = playback.report else { return }
        let segment: ClosedRange<TimeInterval>
        if let start = playback.unreportedStart, let end = playback.lastSample, end > start {
            segment = start...end
        } else if state != .playing, let position = playback.seekPosition,
                  playback.lastReport?.position != position || playback.lastReport?.state != state {
            // A confirmed seek changes the resume position without adding watched time.
            segment = position...position
        } else if let lastReport = playback.lastReport, state != .playing, state != lastReport.state {
            // Send a pause or end at the same position if the watched segment was already sent.
            segment = lastReport.position...lastReport.position
        } else if state == .finished, let position = playback.lastSample {
            segment = position...position
        } else {
            return
        }
        watchHistoryPlayback?.unreportedStart = nil
        watchHistoryPlayback?.seekPosition = nil
        watchHistoryPlayback?.lastReport = (segment.upperBound, state)
        report(segment, state)
    }

    private var currentWatchHistoryTime: TimeInterval? {
        vlcPlayback?.elapsed ?? player.currentItem?.currentTime().seconds
    }

    private func flushWatchHistory(
        at time: TimeInterval? = nil, state: WatchHistorySyncService.PlaybackState
    ) {
        guard seekTask == nil else { return }
        if let time, watchHistoryPlayback?.lastSample != nil {
            collectWatchHistorySample(at: time)
        }
        reportWatchHistory(state)
        watchHistoryPlayback?.lastSample = nil
        if state == .finished { watchHistoryPlayback?.report = nil }
    }

    private func finishPausedWatchHistory(at time: TimeInterval? = nil) {
        guard watchHistoryPlayback?.report != nil else { return }
        if let seekTask {
            finishWatchHistoryAfterSeek = true
            WatchHistorySyncService.shared.prepareHistoryRefresh(after: seekTask)
        } else {
            flushWatchHistory(at: time, state: .finished)
        }
    }

    private func endWatchHistory(at time: TimeInterval? = nil) {
        cancelPendingSeek()
        flushWatchHistory(at: time, state: .finished)
        watchHistoryPlayback = nil
    }

    private func recordWatchHistorySeek(at position: TimeInterval) {
        guard loadState == .readyToPlay, !isChangingResolution, !isFinishingHandoff,
              let video = currentVideo, !video.isLive,
              let history = watchHistoryPlayback, history.videoID == video.id,
              position.isFinite, position >= 0 else { return }
        let isPaused = finishWatchHistoryAfterSeek
            || (vlcPlayback.map { !$0.isPlaying } ?? (player.timeControlStatus == .paused))
        if isPaused, history.report == nil {
            // A seek while already paused needs its own final report if the position changed.
            if let previousPosition = history.lastReport?.position, abs(previousPosition - position) <= 0.001 {
                return
            }
            startWatchHistorySync(videoID: video.id)
        }
        watchHistoryPlayback?.seekPosition = position
        if isPaused { finishPausedWatchHistory() }
    }

    private func cancelPendingSeek() {
        seekTask?.cancel()
        seekTask = nil
        finishWatchHistoryAfterSeek = false
    }

    func play() {
        log.info("play()")
        guard loadState == .readyToPlay, !isFinishingHandoff else { return }
        finishWatchHistoryAfterSeek = false
        if let vlcPlayback {
            resumeWatchHistorySyncIfNeeded(at: vlcPlayback.elapsed)
            vlcPlayback.play()
        } else if !isAirPlayMode, let source = currentVLCSource, currentVideo?.isLive == false {
            guard !isChangingResolution else { return }
            beginResolutionChange { [weak self] in
                guard let self else { return }
                if await self.startVLC(source, selection: self.selectedStreamResolution) { self.play() }
                else if !Task.isCancelled { self.showPlaybackFailure() }
            }
            return
        } else {
            player.play()
        }
        isPlaying = true
    }

    func pause(finalizingWatchHistory: Bool = true) {
        log.info("pause()")
        guard !isFinishingHandoff else { return }
        if finalizingWatchHistory {
            finishPausedWatchHistory(at: currentWatchHistoryTime)
        } else {
            flushWatchHistory(at: currentWatchHistoryTime, state: .paused)
        }
        if let vlcPlayback { vlcPlayback.pause() } else { player.pause() }
        endPlaybackBoost()
        isPlaying = false
    }

    func togglePlayPause() {
        log.info("togglePlayPause() (isPlaying=\(self.isPlaying, privacy: .public))")
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, !isFinishingHandoff else { return }
        let playback = vlcPlayback
        let item = player.currentItem
        guard playback == nil ? item != nil : loadState == .readyToPlay else { return }
        let finishAfterSeek = finishWatchHistoryAfterSeek || !isPlaying
            || !(playback?.isPlaying ?? (player.timeControlStatus != .paused))
        cancelPendingSeek()
        finishWatchHistoryAfterSeek = finishAfterSeek
        flushWatchHistory(at: currentWatchHistoryTime, state: isPlaying ? .playing : .paused)
        log.info("seek(to: \(seconds, privacy: .public)s)")
        seekTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let position: TimeInterval?
            if let playback, vlcPlayback === playback {
                position = await playback.seek(to: seconds)
            } else if playback == nil, let item, player.currentItem === item {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let didSeek = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                position = didSeek ? item.currentTime().seconds : nil
            } else {
                position = nil
            }
            guard !Task.isCancelled else { return }
            seekTask = nil
            defer { finishWatchHistoryAfterSeek = false }
            guard vlcPlayback === playback, playback != nil || player.currentItem === item else { return }
            if let position {
                recordWatchHistorySeek(at: position)
            } else if finishWatchHistoryAfterSeek {
                finishPausedWatchHistory(at: currentWatchHistoryTime)
            }
        }
        if finishAfterSeek, watchHistoryPlayback != nil, let seekTask {
            WatchHistorySyncService.shared.prepareHistoryRefresh(after: seekTask)
        }
    }

    func seekRelative(by delta: TimeInterval) {
        log.info("seekRelative(by: \(delta, privacy: .public)s)")
        seek(to: max(0, min(elapsed + delta, duration)))
    }

    func changeStreamResolution(to resolution: Int?) {
        let options = streamResolutionOptions
        guard !options.isEmpty, resolution != selectedStreamResolution,
              resolution.map(options.contains) ?? true else { return }

        let quality = DownloadManager.shared.currentDownloadQuality
        let candidates = fixedStreamCandidates.filter { candidate in
            if let resolution { return candidate.resolution == resolution }
            return quality.heightCap.map { (candidate.resolution ?? Int.max) <= $0 } ?? true
        }
        beginResolutionChange { [weak self] in
            guard let self else { return }
            if self.vlcPlayback != nil {
                if let hls = self.activeHLSPlayback {
                    let switched = await self.tryVLCHLS(
                        hls.candidate, maxHeight: quality.heightCap, selection: resolution,
                        cachedPlaylist: hls.playlist, continuing: true
                    )
                    if !switched, !Task.isCancelled { self.resolutionChangeFailed = true }
                } else {
                    for candidate in candidates {
                        guard !Task.isCancelled else { return }
                        if await self.tryVLCCandidate(candidate, maxHeight: quality.heightCap, selection: resolution, continuing: true) {
                            return
                        }
                    }
                    if !Task.isCancelled { self.resolutionChangeFailed = true }
                }
            } else if let item = self.player.currentItem {
                await self.switchNativeStream(candidates, quality: quality, resolution: resolution, from: item)
            }
        }
    }

    func startAirPlay() {
        guard canUseAirPlay, !isAirPlayMode, let source = currentVLCSource, let playback = vlcPlayback else { return }
        beginResolutionChange { [weak self, weak playback] in
            guard let self, let playback else { return }
            await self.handoffToAirPlay(source, from: playback)
        }
    }

    func stopAirPlay() {
        guard isAirPlayMode, !isChangingResolution else { return }
        guard let source = currentVLCSource else {
            isAirPlayMode = false
            player.allowsExternalPlayback = false
            isExternalPlaybackActive = false
            return
        }

        beginResolutionChange { [weak self] in
            guard let self else { return }
            let selection = self.selectedStreamResolution
            let started: Bool
            if source.playlistData == nil, let hls = self.activeHLSPlayback {
                started = await self.tryVLCHLS(
                    hls.candidate, maxHeight: source.maximumResolution, selection: selection,
                    cachedPlaylist: hls.playlist, continuing: true
                )
            } else {
                started = await self.startVLC(source, selection: selection, continuing: true)
            }
            if !Task.isCancelled, !started { self.airPlayHandoffFailed = true }
        }
    }

    func playNext() {
        log.info("playNext() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        if let next = queue.advance() {
            load(next, expandPlayer: false)
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
                self.load(next, expandPlayer: false)
            }
        }
    }

    func playPrevious() {
        log.info("playPrevious() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        guard let previous = queue.previous() else {
            log.notice("playPrevious: at start of queue, nothing to go back to")
            return
        }
        load(previous, expandPlayer: false)
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
        player.removeAllItems()
        NowPlayingCenter.clear()
    }

    // MARK: - Internals

    private func beginResolutionChange(_ operation: @escaping @MainActor () async -> Void) {
        endPlaybackBoost()
        isChangingResolution = true
        resolutionChangeTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard !Task.isCancelled, let self else { return }
            self.isChangingResolution = false
            self.isFinishingHandoff = false
            self.resolutionChangeTask = nil
        }
    }

    private func resetStreamResolution(keepingAirPlay: Bool = false) {
        endPlaybackBoost()
        endWatchHistory(at: currentWatchHistoryTime)
        clearYouTubeSubtitleSelection()
        youtubeSubtitleListTask?.cancel()
        youtubeSubtitleListTask = nil
        youtubeSubtitleTracks = []
        youtubeSubtitleListState = .idle
        youtubeSubtitleLoadFailed = false
        resolutionChangeTask?.cancel()
        resolutionChangeTask = nil
        stagedVLCPlayback?.stop()
        stagedVLCPlayback = nil
        stopVLCPlayback()
        clearNativeTracks()
        hlsPlaylistTask?.cancel()
        hlsPlaylistTask = nil
        isChangingResolution = false
        isFinishingHandoff = false
        isAirPlayMode = keepingAirPlay
        if !keepingAirPlay {
            player.allowsExternalPlayback = false
            isExternalPlaybackActive = false
        }
        currentVLCSource = nil
        activeStreamKind = nil
        activeHLSPlayback = nil
        fixedStreamCandidates = []
        playbackResolution = nil
        selectedStreamResolution = nil
        resolutionChangeFailed = false
        airPlayHandoffFailed = false
        shouldRecordWatchHistory = false
    }

    private func startVLC(
        _ source: VLCSource, selection: Int? = nil, continuing: Bool = false, startAt: TimeInterval = 0
    ) async -> Bool {
        guard !Task.isCancelled, stagedVLCPlayback == nil else { return false }
        let playback: VLCKitPlayback
        do {
            if let playlist = source.playlistData {
                playback = try VLCKitPlayback(playlistData: playlist)
            } else {
                playback = try VLCKitPlayback(url: source.url)
            }
        } catch {
            log.notice("Could not open source in VLCKit")
            return false
        }

        stagedVLCPlayback = playback
        defer {
            if stagedVLCPlayback === playback {
                stagedVLCPlayback = nil
                playback.stop()
            }
        }
        guard await playback.prepare(), !Task.isCancelled, stagedVLCPlayback === playback else {
            logVLCFailure(playback)
            return false
        }

        let previousVLC = vlcPlayback
        let previousAV = player.currentItem
        let resume = continuing && (previousVLC?.isPlaying ?? (player.timeControlStatus != .paused))
        let position = continuing ? (previousVLC?.elapsed ?? previousAV?.currentTime().seconds ?? elapsed) : startAt
        if continuing {
            pause(finalizingWatchHistory: false)
            isFinishingHandoff = true
        }
        let target = continuing || playback.duration <= 0 || position < playback.duration ? position : 0
        let started = await playback.finish(at: target.isFinite ? max(0, target) : 0, autoplay: resume, rate: player.defaultRate)
        guard !Task.isCancelled, stagedVLCPlayback === playback else { return false }
        isFinishingHandoff = false

        let resolution = Self.resolution(of: playback.videoSize)
        let matchesSelection = source.resolution.map { expected in
            resolution.map { abs($0 - expected) <= 16 } ?? false
        } ?? true
        let respectsLimit = source.maximumResolution.map { limit in
            resolution.map { $0 <= limit + 16 } ?? true
        } ?? true
        guard started, matchesSelection, source.resolution != nil || respectsLimit else {
            playback.stop()
            if resume { play() }
            logVLCFailure(playback)
            return false
        }

        stopVLCPlayback()
        stagedVLCPlayback = nil
        player.allowsExternalPlayback = false
        player.removeAllItems()
        isAirPlayMode = false
        isExternalPlaybackActive = false
        currentVLCSource = source
        vlcPlayback = playback
        syncVLCTracks(playback)
        clearNativeTracks()
        playback.onEvent = { [weak self, weak playback] event in
            guard let self, let playback else { return }
            self.handleVLCEvent(event, playback: playback)
        }
        selectedStreamResolution = selection
        playbackResolution = resolution
        loadState = .readyToPlay
        syncVLCPlaybackState(playback)
        let size = playback.videoSize
        log.info("VLCKit stream ready: size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
        return true
    }

    private func logVLCFailure(_ playback: VLCKitPlayback) {
        guard !Task.isCancelled else { return }
        let reason = playback.startupFailureReason ?? "unexpected presentation size"
        log.notice("VLCKit failed to prepare playback (\(reason, privacy: .public))")
    }

    private func stopVLCPlayback() {
        guard let playback = vlcPlayback else { return }
        cancelPendingSeek()
        isHoldingPlaybackBoost = false
        vlcPlayback = nil
        vlcTracks = [:]
        playback.onEvent = nil
        playback.stop()
    }

    private func handleVLCEvent(_ event: VLCKitPlayback.Event, playback: VLCKitPlayback) {
        guard vlcPlayback === playback else { return }
        switch event {
        case .update:
            syncVLCPlaybackState(playback)
        case .tracksChanged:
            syncVLCTracks(playback)
        case .ended:
            endWatchHistory(at: playback.elapsed)
            stopVLCPlayback()
            shouldRecordWatchHistory = !isFromURLFile
            isPlaying = false
            elapsed = playback.duration
            updateNowPlaying()
            if preferences.autoplayNext, !isFromURLFile, !isChangingResolution { playNext() }
        case .failed:
            endWatchHistory()
            stopVLCPlayback()
            if !isChangingResolution { showPlaybackFailure() }
        }
    }

    private func syncVLCTracks(_ playback: VLCKitPlayback) {
        vlcTracks = [
            .audio: playback.tracks(for: .audio),
            .subtitle: playback.tracks(for: .subtitle)
        ]
        if selectedYouTubeSubtitleID != nil { disableStreamSubtitles() }
    }

    private func handoffToAirPlay(_ source: VLCSource, from playback: VLCKitPlayback) async {
        guard !Task.isCancelled, vlcPlayback === playback else { return }
        let item = AVPlayerItem(url: source.url)
        if activeStreamKind == .hlsMaster {
            applyStreamLimit(selectedStreamResolution ?? source.maximumResolution, to: item)
        }
        player.allowsExternalPlayback = true
        guard await prepareStream(item, label: "AirPlay source"), !Task.isCancelled, vlcPlayback === playback else {
            if !Task.isCancelled {
                if player.currentItem === item { player.removeAllItems() }
                player.allowsExternalPlayback = false
                airPlayHandoffFailed = true
            }
            return
        }

        let position = playback.elapsed
        let resume = playback.isPlaying
        pause(finalizingWatchHistory: false)
        isFinishingHandoff = true
        var didSeek = true
        if position.isFinite, position > 0 {
            let target = CMTime(seconds: position, preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            didSeek = await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        guard !Task.isCancelled, vlcPlayback === playback else { return }
        isFinishingHandoff = false
        guard player.currentItem === item, didSeek, item.status == .readyToPlay else {
            player.removeAllItems()
            player.allowsExternalPlayback = false
            if resume { play() }
            airPlayHandoffFailed = true
            return
        }

        stopVLCPlayback()
        isAirPlayMode = true
        isExternalPlaybackActive = player.isExternalPlaybackActive
        syncNativePlaybackState()
        if resume { play() }
        log.info("AirPlay source ready in AVPlayer")
    }

    private func showPlaybackFailure() {
        isPlaying = false
        loadState = .failed(ErrorState(from: YouTubeServiceError.streamExtractionFailed).message)
        updateNowPlaying()
    }

    private func syncVLCPlaybackState(_ playback: VLCKitPlayback) {
        if playback.elapsed.isFinite, playback.elapsed >= 0 { elapsed = playback.elapsed }
        if playback.duration.isFinite, playback.duration > 0 { duration = playback.duration }
        if let resolution = Self.resolution(of: playback.videoSize) { playbackResolution = resolution }
        isPlaying = playback.isPlaying
        if isPlaying {
            recordWatchHistoryIfNeeded(at: elapsed)
            sampleWatchHistory(at: elapsed)
        } else {
            if !isChangingResolution { finishPausedWatchHistory(at: elapsed) }
        }
        updateNowPlaying()
    }

    private func syncNativePlaybackState() {
        guard let item = player.currentItem else { return }
        let position = item.currentTime().seconds
        if position.isFinite { elapsed = position }
        let total = item.duration.seconds
        if total.isFinite { duration = total }
        playbackResolution = Self.resolution(of: item.presentationSize)
        updateNowPlaying()
    }

    private static func resolution(of size: CGSize) -> Int? {
        let dimension = min(size.width, size.height)
        return dimension > 0 ? Int(exactly: dimension.rounded()) : nil
    }

    private func switchNativeStream(
        _ candidates: [StreamCandidate], quality: VideoQuality, resolution: Int?, from previousItem: AVPlayerItem
    ) async {
        guard !Task.isCancelled, player.currentItem === previousItem else { return }
        let position = previousItem.currentTime()
        let isLive = currentVideo?.isLive == true
        let programDate = isLive ? previousItem.currentDate() : nil
        func restorePosition() async -> Bool {
            if let programDate { return await player.seek(to: programDate) }
            if !isLive, position.isNumeric, position.seconds > 0 {
                return await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return true
        }

        let resume = player.timeControlStatus != .paused
        let previousKind = activeStreamKind
        let previousHLS = activeHLSPlayback
        let previousSelection = previousItem.currentMediaSelection
        pause(finalizingWatchHistory: false)
        loadState = .resolving

        var switched: Bool
        if let previousHLS {
            switched = await tryHLSStream(
                previousHLS.candidate, maxHeight: quality.heightCap,
                preferHighest: quality == .highest || quality == .p2160,
                exactResolution: resolution, cachedPlaylist: previousHLS.playlist
            )
        } else {
            var attempted: Set<URL> = []
            switched = await tryStreams(candidates, maxHeight: nil, attempted: &attempted, limit: 3)
        }
        guard !Task.isCancelled else { return }
        if switched { switched = await restorePosition() }
        guard !Task.isCancelled else { return }
        if switched {
            if let item = player.currentItem {
                await restoreMediaSelection(previousSelection, from: previousItem.asset, to: item)
            }
            guard !Task.isCancelled else { return }
            selectedStreamResolution = resolution
        } else {
            if player.currentItem !== previousItem { loadItem(previousItem) }
            activateStream(previousKind, hls: previousHLS)
            loadState = .readyToPlay
            _ = await restorePosition()
        }
        guard !Task.isCancelled else { return }
        if resume { play() }
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
        if vlcPlayback == nil {
            endPlaybackBoost()
            cancelPendingSeek()
        }
        flushWatchHistory(state: .paused)
        clearNativeTracks()
        if vlcPlayback == nil { playbackResolution = nil }
        player.removeAllItems()
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
                guard self.vlcPlayback == nil, self.player.currentItem === item else { return }
                let resolution = Self.resolution(of: item.presentationSize)
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
                    self.loadNativeTracks(for: item)
                    self.log.info("AVPlayerItem status: readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
                case .failed:
                    let error = item.error ?? YouTubeServiceError.streamExtractionFailed
                    if self.vlcPlayback == nil, !isStreamCandidate || self.loadState == .readyToPlay {
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

    private func clearNativeTracks() {
        nativeTrackLoadTask?.cancel()
        nativeTrackLoadTask = nil
        nativeTrackGroups = [:]
        nativeMediaSelection = nil
    }

    private func loadNativeTracks(for item: AVPlayerItem) {
        nativeTrackLoadTask?.cancel()
        nativeTrackLoadTask = Task { [weak self, weak item] in
            guard let item else { return }
            async let audio = try? item.asset.loadMediaSelectionGroup(for: .audible)
            async let subtitles = try? item.asset.loadMediaSelectionGroup(for: .legible)
            let groups = await (audio, subtitles)
            guard !Task.isCancelled, let self, player.currentItem === item else { return }
            nativeTrackGroups = [.audio: groups.0, .subtitle: groups.1].compactMapValues { $0 }
            nativeMediaSelection = item.currentMediaSelection
            nativeTrackLoadTask = nil
            if selectedYouTubeSubtitleID != nil, !isAirPlayMode, vlcPlayback == nil {
                disableStreamSubtitles()
            }
        }
    }

    private func resolveAndPlay(
        video: Video, fileURL: URL? = nil, autoplay: Bool, skipRecommendations: Bool, startAt: TimeInterval = 0
    ) async {
        guard !Task.isCancelled else { return }
        let localFile = fileURL ?? DownloadManager.shared.localFile(for: video.id)
        var started = await startPlayback(videoID: video.id, localFile: localFile, startAt: startAt)
        if !started, startAt > 0, !Task.isCancelled {
            log.notice("Could not start playback at the YouTube history position. Retrying from the beginning.")
            started = await startPlayback(videoID: video.id, localFile: localFile, startAt: 0)
        }
        guard !Task.isCancelled else { return }
        guard started else {
            showPlaybackFailure()
            return
        }

        updateNowPlaying()
        if autoplay { play() }
        if !skipRecommendations {
            await fillQueueWithRecommendations(for: video)
        }
    }

    private func startPlayback(videoID: String, localFile: URL?, startAt: TimeInterval) async -> Bool {
        if let localFile {
            let source = VLCSource(url: localFile)
            if isAirPlayMode { return await startNativeAirPlaySource(source, startAt: startAt) }
            return await startVLC(source, startAt: startAt)
        }
        return await startStreaming(videoID: videoID, startAt: startAt)
    }

    private func startStreaming(videoID: String, startAt: TimeInterval) async -> Bool {
        let quality = DownloadManager.shared.currentDownloadQuality
        log.info("Resolving stream quality=\(quality.rawValue, privacy: .public)")
        if currentVideo?.isLive == false || quality == .highest || quality == .p2160 {
            return await startHighestStream(videoID: videoID, maxHeight: quality.heightCap, startAt: startAt)
        }

        let maxHeight = quality.heightCap
        var attempted: Set<URL> = []
        var fixedStreams: [StreamCandidate] = []

        for source in StreamSource.allCases {
            guard !Task.isCancelled else { return false }
            let candidates = await streamCandidates(videoID: videoID, source: source)
            fixedStreams.append(contentsOf: candidates.filter { $0.kind != .hlsMaster })
            let masters = candidates.filter { $0.kind == .hlsMaster }
            let limit = source == .ytDlp || source == .ytDlpVisionOS ? 2 : 1
            if await tryStreams(masters, maxHeight: maxHeight, attempted: &attempted, limit: limit, startAt: startAt) {
                return true
            }
        }

        guard !Task.isCancelled else { return false }
        fixedStreamCandidates = fixedStreams.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        let eligible = fixedStreamCandidates.filter { candidate in
            maxHeight.map { (candidate.height ?? Int.max) <= $0 } ?? true
        }
        return await tryStreams(eligible, maxHeight: maxHeight, attempted: &attempted, limit: 3, startAt: startAt)
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

    private func startHighestStream(videoID: String, maxHeight: Int?, startAt: TimeInterval) async -> Bool {
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
            let available = sources.flatMap { received[$0] ?? [] }
            let ranked = Self.rankStreams(available, maxHeight: maxHeight)
            fixedStreamCandidates = Self.rankStreams(available.filter { $0.kind != .hlsMaster }, maxHeight: nil)
            if await tryStreams(
                ranked, maxHeight: maxHeight, attempted: &attempted, limit: 8 - attempted.count,
                preferHighestHLS: true, startAt: startAt
            ) {
                return true
            }
            guard attempted.count < 8, received.count < sources.count,
                  let (source, candidates) = await iterator.next() else { break }
            if let source { received[source] = candidates }
        }

        // An advertised visionOS playlist can still fail preparation on this device.
        guard !Task.isCancelled, received[.ytDlpVisionOS]?.contains(where: { $0.kind == .hlsMaster }) == true else { return false }
        let candidates = await inspectStreamCandidates(videoID: videoID, source: .ytDlp)
        guard !Task.isCancelled else { return false }
        let fallback = Self.rankStreams(candidates, maxHeight: maxHeight)
        fixedStreamCandidates.append(contentsOf: fallback.filter { $0.kind != .hlsMaster })
        fixedStreamCandidates.sort { ($0.resolution ?? 0) > ($1.resolution ?? 0) }
        return await tryStreams(
            fallback, maxHeight: maxHeight, attempted: &attempted, limit: 3, preferHighestHLS: true, startAt: startAt
        )
    }

    private static func rankStreams(_ candidates: [StreamCandidate], maxHeight: Int?) -> [StreamCandidate] {
        let cap = maxHeight ?? Int.max
        return candidates.filter { $0.kind == .hlsMaster || ($0.height ?? Int.max) <= cap }.sorted { lhs, rhs in
            let lhsResolution = lhs.manifestResolutions.last(where: { $0 <= cap }) ?? lhs.resolution ?? 0
            let rhsResolution = rhs.manifestResolutions.last(where: { $0 <= cap }) ?? rhs.resolution ?? 0
            if lhsResolution != rhsResolution { return lhsResolution > rhsResolution }
            return lhs.kind == .hlsMaster && rhs.kind != .hlsMaster
        }
    }

    private func inspectStreamCandidates(videoID: String, source: StreamSource) async -> [StreamCandidate] {
        var candidates = await streamCandidates(videoID: videoID, source: source)
        for index in candidates.indices where candidates[index].kind == .hlsMaster {
            guard !Task.isCancelled else { return [] }
            if candidates[index].manifestResolutions.isEmpty {
                let url = candidates[index].url
                if let playlist = await inspectHLSPlaylist(at: url), !playlist.resolutions.isEmpty {
                    candidates[index].playlist = playlist
                    candidates[index].manifestResolutions = Array(playlist.resolutions.reversed())
                } else if !Task.isCancelled {
                    candidates[index].manifestResolutions = await hlsResolutions(at: url)
                }
            }
            guard !Task.isCancelled else { return [] }
            let label = candidates[index].manifestResolutions.map { "\($0)p" }.joined(separator: ", ")
            log.info("HLS resolutions from \(source.rawValue, privacy: .public): \(label.isEmpty ? "unknown" : label, privacy: .public)")
        }
        return candidates
    }

    private func inspectHLSPlaylist(at url: URL) async -> HLSResolutionPlaylist? {
        await withTaskGroup(of: HLSResolutionPlaylist?.self) { group in
            group.addTask { try? await HLSResolutionPlaylist.load(from: url) }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let playlist = await group.next() ?? nil
            group.cancelAll()
            return playlist
        }
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
        _ candidates: [StreamCandidate], maxHeight: Int?, attempted: inout Set<URL>, limit: Int,
        preferHighestHLS: Bool = false, startAt: TimeInterval = 0
    ) async -> Bool {
        var remaining = limit
        for candidate in candidates {
            guard remaining > 0, !Task.isCancelled else { return false }
            guard attempted.insert(candidate.url).inserted else { continue }
            remaining -= 1

            if currentVideo?.isLive == false {
                if isAirPlayMode {
                    let source = VLCSource(url: candidate.url, maximumResolution: maxHeight)
                    if await startNativeAirPlaySource(source, candidate: candidate, startAt: startAt) { return true }
                } else if await tryVLCCandidate(candidate, maxHeight: maxHeight, startAt: startAt) {
                    return true
                }
                continue
            }
            player.allowsExternalPlayback = true

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

    private func startNativeAirPlaySource(
        _ source: VLCSource, candidate: StreamCandidate? = nil, startAt: TimeInterval
    ) async -> Bool {
        player.allowsExternalPlayback = true
        let item = AVPlayerItem(url: source.url)
        if candidate?.kind == .hlsMaster { applyStreamLimit(source.maximumResolution, to: item) }
        guard await prepareStream(item, label: "AirPlay source"), !Task.isCancelled else { return false }
        let duration = item.duration.seconds
        if startAt > 0, !duration.isFinite || duration <= 0 || startAt < duration {
            let target = CMTime(seconds: startAt, preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            let didSeek = await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
            guard !Task.isCancelled, player.currentItem === item else { return false }
            guard didSeek, item.status == .readyToPlay else {
                player.removeAllItems()
                return false
            }
        }
        currentVLCSource = source
        let master = candidate.flatMap { candidate in
            candidate.kind == .hlsMaster
                ? HLSPlayback(candidate: candidate, playlist: candidate.playlist, loader: nil, resolution: nil)
                : nil
        }
        activateStream(candidate?.kind, hls: master)
        loadState = .readyToPlay
        syncNativePlaybackState()
        return true
    }

    private func tryVLCCandidate(
        _ candidate: StreamCandidate, maxHeight: Int?, selection: Int? = nil, continuing: Bool = false,
        startAt: TimeInterval = 0
    ) async -> Bool {
        if candidate.kind == .hlsMaster {
            return await tryVLCHLS(
                candidate, maxHeight: maxHeight, selection: selection, continuing: continuing, startAt: startAt
            )
        }
        let source = VLCSource(url: candidate.url, resolution: selection, maximumResolution: maxHeight)
        guard await startVLC(source, selection: selection, continuing: continuing, startAt: startAt) else { return false }
        activateStream(candidate.kind)
        return true
    }

    private func tryVLCHLS(
        _ candidate: StreamCandidate, maxHeight: Int?, selection: Int?,
        cachedPlaylist: HLSResolutionPlaylist? = nil, continuing: Bool = false, startAt: TimeInterval = 0
    ) async -> Bool {
        var playlist = cachedPlaylist ?? candidate.playlist
        if playlist == nil { playlist = try? await HLSResolutionPlaylist.load(from: candidate.url) }
        guard !Task.isCancelled else { return false }

        let eligible = playlist?.resolutions.filter { $0 <= (maxHeight ?? Int.max) } ?? []
        let attempts = selection.map { [$0] } ?? Array(eligible.prefix(3))
        for resolution in attempts {
            for codec in [HLSResolutionPlaylist.VLCCodecSelection.vp9, .other] {
                guard !Task.isCancelled else { return false }
                guard let data = playlist?.vlcPlaybackData(resolution: resolution, codec: codec) else { continue }
                let source = VLCSource(url: candidate.url, playlistData: data, resolution: resolution, maximumResolution: maxHeight)
                log.info("Trying VLCKit HLS resolution=\(resolution, privacy: .public)p codec=\(codec.rawValue, privacy: .public)")
                if await startVLC(source, selection: selection, continuing: continuing, startAt: startAt) {
                    activateStream(.hlsMaster, hls: HLSPlayback(candidate: candidate, playlist: playlist, loader: nil, resolution: resolution))
                    return true
                }
            }
        }

        guard selection == nil, !Task.isCancelled else { return false }
        for codec in [HLSResolutionPlaylist.VLCCodecSelection.preferVP9, .all] {
            guard !Task.isCancelled else { return false }
            let data = codec == .preferVP9 || maxHeight != nil
                ? playlist?.vlcPlaybackData(maximumResolution: maxHeight, codec: codec)
                : nil
            guard data != nil || (codec == .all && maxHeight == nil) else { continue }
            let source = VLCSource(url: candidate.url, playlistData: data, maximumResolution: maxHeight)
            if await startVLC(source, continuing: continuing, startAt: startAt) {
                activateStream(.hlsMaster, hls: HLSPlayback(candidate: candidate, playlist: playlist, loader: nil, resolution: nil))
                return true
            }
        }
        return false
    }

    private func tryHLSStream(
        _ candidate: StreamCandidate, maxHeight: Int?, preferHighest: Bool,
        exactResolution: Int? = nil, cachedPlaylist: HLSResolutionPlaylist? = nil
    ) async -> Bool {
        var playlist = cachedPlaylist ?? candidate.playlist
        if playlist == nil, preferHighest || exactResolution != nil {
            playlist = try? await HLSResolutionPlaylist.load(from: candidate.url)
        }
        guard !Task.isCancelled else { return false }

        let label = streamLabel(candidate)
        if let playlist {
            let eligible = playlist.resolutions.filter { $0 <= (maxHeight ?? Int.max) }
            let attempts = exactResolution.map { [$0] } ?? (preferHighest ? Array(eligible.prefix(3)) : [])
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
            MainActor.assumeIsolated {
                guard self.vlcPlayback == nil else { return }
                self.sampleWatchHistory(at: time.seconds)
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
                guard let self, self.vlcPlayback == nil, self.player.currentItem === item,
                      self.seekTask == nil else { return }
                self.flushWatchHistory(state: .playing)
                self.recordWatchHistorySeek(at: item.currentTime().seconds)
            }
        }

        nativeMediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem === item else { return }
                self.nativeMediaSelection = item.currentMediaSelection
            }
        }

        // Auto-advance on item end.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard self.vlcPlayback == nil, self.loadState == .readyToPlay,
                      self.player.currentItem == nil || self.player.currentItem === item else { return }
                self.isHoldingPlaybackBoost = false
                self.endWatchHistory(at: item.currentTime().seconds)
                self.shouldRecordWatchHistory = !self.isFromURLFile
                self.isPlaying = false
                self.updateNowPlaying()
                if self.preferences.autoplayNext, !self.isFromURLFile { self.playNext() }
            }
        }

        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, change in
            guard let self, let active = change.newValue else { return }
            Task { @MainActor in
                guard self.player.isExternalPlaybackActive == active else { return }
                let wasActive = self.isExternalPlaybackActive
                self.isExternalPlaybackActive = active
                if wasActive, !active, self.isAirPlayMode, self.loadState == .readyToPlay, self.player.currentItem != nil {
                    self.stopAirPlay()
                }
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let speed = player.defaultRate
                guard speed.isFinite, speed > 0 else { return }
                storePlaybackSpeed(speed)
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            let observedItem = avPlayer.currentItem
            Task { @MainActor in
                guard self.vlcPlayback == nil, self.player.timeControlStatus == status,
                      self.player.currentItem === observedItem else { return }
                switch status {
                case .playing:
                    if let observedItem {
                        let time = observedItem.currentTime().seconds
                        self.recordWatchHistoryIfNeeded(at: time)
                        self.resumeWatchHistorySyncIfNeeded(at: time)
                        if self.watchHistoryPlayback?.lastSample == nil {
                            self.collectWatchHistorySample(at: time)
                        }
                    }
                    if !self.isPlaying {
                        self.log.info("KVO timeControlStatus → playing (sync isPlaying=true)")
                        self.isPlaying = true
                    }
                case .paused:
                    self.endPlaybackBoost()
                    if !self.isChangingResolution {
                        self.finishPausedWatchHistory(at: observedItem?.currentTime().seconds)
                    }
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
