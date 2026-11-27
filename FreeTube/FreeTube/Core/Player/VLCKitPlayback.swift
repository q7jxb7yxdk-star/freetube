import OSLog
import UIKit
import VLCKit

@MainActor
final class VLCKitPlayback: NSObject, VLCMediaPlayerDelegate {
    enum Event {
        case update
        case tracksChanged
        case ended
        case failed
    }

    private enum State {
        case idle
        case preparing
        case ready
        case finishing
        case active
        case stopped
    }

    let drawable = UIView()
    var onEvent: ((Event) -> Void)?
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var videoSize = CGSize.zero
    private(set) var startupFailureReason: String?

    private let player: VLCMediaPlayer
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "VLCKitPlayback")
    private let expectsVideo: Bool
    private let temporaryPlaylistURL: URL?
    private var state = State.idle
    private var startupStage = "waiting for the video surface"
    private var bufferingFinished = false

    convenience init(url: URL) throws {
        guard let media = VLCMedia(url: url) else { throw URLError(.unsupportedURL) }
        self.init(media: media)
    }

    convenience init(playlistData: Data) throws {
        let playlistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeTube-\(UUID().uuidString).m3u8")
        try playlistData.write(to: playlistURL, options: [.atomic, .completeFileProtection])
        guard let media = VLCMedia(url: playlistURL) else {
            try? FileManager.default.removeItem(at: playlistURL)
            throw URLError(.cannotOpenFile)
        }
        let variantPrefix = "#EXT-X-STREAM-INF:"
        let variants = String(decoding: playlistData, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix(variantPrefix) }
        // A generated master can describe video before the live track list is populated.
        let expectsVideo = !variants.isEmpty && variants.allSatisfy {
            $0.dropFirst(variantPrefix.count).contains(#/(?:^|,)RESOLUTION=[1-9][0-9]*x[1-9][0-9]*(?:,|$)/#)
        }
        self.init(media: media, temporaryPlaylistURL: playlistURL, expectsVideo: expectsVideo)
    }

    private init(media: VLCMedia, temporaryPlaylistURL: URL? = nil, expectsVideo: Bool = false) {
        self.temporaryPlaylistURL = temporaryPlaylistURL
        self.expectsVideo = expectsVideo
        player = VLCMediaPlayer(options: ["--quiet"])
        super.init()

        player.drawable = drawable
        player.timeChangeUpdateInterval = 0.25
        player.media = media
        player.delegate = self
    }

    deinit {
        if let temporaryPlaylistURL { try? FileManager.default.removeItem(at: temporaryPlaylistURL) }
    }

    func start(at seconds: TimeInterval, autoplay: Bool, rate: Float) async -> Bool {
        guard seconds.isFinite, await prepare() else { return false }
        return await finish(at: seconds, autoplay: autoplay, rate: rate)
    }

    func prepare() async -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        defer {
            if state == .preparing { failStartup() }
        }
        let deadline = ContinuousClock.now + .seconds(12)
        // The iOS video output creates its framebuffer from the drawable's initial layout.
        guard await wait(in: .preparing, until: deadline, for: {
            (self.drawable.superview as? VLCKitSurface.Container)?.isReadyForPlayback(self.drawable) == true
        }), state == .preparing, !Task.isCancelled else { return false }
        startupStage = "preparing muted audio"
        guard let audio = player.audio else { return false }
        // Let the decoder prime normally with the previous video surface still visible.
        audio.isMuted = true
        startupStage = "waiting for playback tracks"
        player.play()
        guard await wait(in: .preparing, until: deadline, for: {
            self.isReadyToPlay
        }), state == .preparing, !Task.isCancelled, player.state == .playing else { return false }
        startupStage = "waiting for playback handoff"
        state = .ready
        return true
    }

    func finish(at seconds: TimeInterval, autoplay: Bool, rate: Float) async -> Bool {
        guard state == .ready else { return false }
        state = .finishing
        defer {
            if state == .finishing { failStartup() }
        }
        guard seconds.isFinite, !Task.isCancelled, !hasStartupPlaybackStopped, let audio = player.audio else {
            return false
        }
        let deadline = ContinuousClock.now + .seconds(4)
        startupStage = "seeking to the previous position"
        let target = clampedTime(seconds)
        if abs((nativeElapsed ?? 0) - target) > 0.5 && (target > 0 || player.isSeekable) {
            guard await wait(in: .finishing, until: deadline, for: { self.player.isSeekable }),
                  let time = nativeTime(for: target) else { return false }
            player.time = time
            guard await wait(in: .finishing, until: deadline, for: {
                guard let time = self.nativeElapsed else { return false }
                return abs(time - target) <= 0.5
            }), state == .finishing, !Task.isCancelled, !hasStartupPlaybackStopped else { return false }
        }

        if rate.isFinite, rate > 0 { player.rate = rate }
        let expectedState: VLCMediaPlayerState = autoplay ? .playing : .paused
        if autoplay {
            startupStage = "restoring the playing state"
            if player.state == .paused { player.play() }
        } else {
            startupStage = "restoring the paused state"
            player.pause()
        }
        guard await wait(in: .finishing, until: deadline, for: { self.player.state == expectedState }) else {
            return false
        }
        sample()
        guard state == .finishing, !Task.isCancelled, player.state == expectedState else { return false }
        state = .active
        audio.isMuted = false
        return true
    }

    func play() {
        guard state == .active else { return }
        player.play()
    }

    func pause() {
        guard state == .active else { return }
        player.pause()
    }

    func setPlaybackSpeed(_ speed: Float) {
        guard state == .active else { return }
        player.rate = speed
    }

    func tracks(for kind: PlaybackTrackKind) -> [PlaybackTrack] {
        nativeTracks(for: kind).map {
            PlaybackTrack(id: $0.trackId, title: $0.trackName, isSelected: $0.isSelected)
        }
    }

    func selectTrack(_ id: String?, for kind: PlaybackTrackKind) {
        guard state == .active else { return }
        switch kind {
        case .audio:
            guard let id else { return }
            player.audioTracks.first { $0.trackId == id }?.isSelectedExclusively = true
        case .subtitle:
            guard let id else {
                log.info("VLC subtitle off requested")
                player.deselectAllTextTracks()
                return
            }
            let tracks = player.textTracks
            guard let track = tracks.first(where: { $0.trackId == id }) else {
                log.notice("VLC subtitle selection requested for an unavailable track (available=\(tracks.count, privacy: .public))")
                return
            }
            log.info("VLC subtitle selection requested (alreadySelected=\(track.isSelected, privacy: .public))")
            player.selectTextTracks([track])
        }
    }

    private func nativeTracks(for kind: PlaybackTrackKind) -> [VLCMediaPlayer.Track] {
        switch kind {
        case .audio: player.audioTracks
        case .subtitle: player.textTracks
        }
    }

    func seek(to seconds: TimeInterval) async -> TimeInterval? {
        guard state == .active, !Task.isCancelled, seconds.isFinite, player.isSeekable else { return nil }
        let target = clampedTime(seconds)
        let previous = nativeElapsed
        if let previous, abs(previous - target) <= 0.001 { return previous }

        // Setting the native clock leaves the current play/pause state in place.
        var landedPosition: TimeInterval?
        let requestedJump: Bool
        if let previous,
           let currentMilliseconds = Int32(exactly: (previous * 1000).rounded()),
           let targetMilliseconds = Int32(exactly: (target * 1000).rounded()) {
            requestedJump = player.jump(withOffset: targetMilliseconds - currentMilliseconds) { [weak self] in
                Task { @MainActor in landedPosition = self?.nativeElapsed }
            }
        } else {
            requestedJump = false
        }
        if !requestedJump {
            guard let time = nativeTime(for: target) else { return nil }
            player.time = time
        }

        let tolerance = min(0.5, max(0.001, abs((previous ?? 0) - target) / 2))
        let deadline = ContinuousClock.now + .seconds(4)
        guard await wait(in: .active, until: deadline, for: {
            if landedPosition != nil { return true }
            guard let position = self.nativeElapsed else { return false }
            return abs(position - target) <= tolerance
        }), state == .active, !Task.isCancelled else { return nil }

        publishUpdate()
        return landedPosition ?? nativeElapsed
    }

    func stop() {
        guard state != .stopped else { return }
        state = .stopped
        isPlaying = false
        player.delegate = nil
        player.audio?.isMuted = true
        player.stop()
        if let temporaryPlaylistURL {
            try? FileManager.default.removeItem(at: temporaryPlaylistURL)
        }
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        let rawValue = newState.rawValue
        Task { @MainActor [weak self] in
            guard let newState = VLCMediaPlayerState(rawValue: rawValue) else { return }
            self?.handleState(newState)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.publishUpdate() }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in self?.bufferingFinished = progress >= 1 }
    }

    nonisolated func mediaPlayerTrackAdded(_ trackID: String, with trackType: VLCMedia.TrackType) {
        publishTrackChange()
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackID: String, with trackType: VLCMedia.TrackType) {
        publishTrackChange()
    }

    nonisolated func mediaPlayerTrackUpdated(_ trackID: String, with trackType: VLCMedia.TrackType) {
        publishTrackChange()
        Task { @MainActor [weak self] in self?.publishUpdate() }
    }

    nonisolated func mediaPlayerTrackSelected(_ type: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
        publishTrackChange(subtitleSelectionChanged: type == .text)
    }

    private nonisolated func publishTrackChange(subtitleSelectionChanged: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self, state == .active else { return }
            if subtitleSelectionChanged {
                let selectedCount = player.textTracks.count(where: \.isSelected)
                log.info("VLC reported a subtitle selection change (selected=\(selectedCount, privacy: .public))")
            }
            onEvent?(.tracksChanged)
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        guard length > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self, state != .idle && state != .stopped else { return }
            duration = TimeInterval(length) / 1000
            publishUpdate()
        }
    }

    private var hasDrawable: Bool {
        drawable.window != nil && drawable.bounds.width > 0 && drawable.bounds.height > 0
    }

    private var decodedVideoSize: CGSize? {
        guard player.hasVideoOut else { return nil }
        let size = player.videoSize
        return size.width > 0 && size.height > 0 ? size : nil
    }

    private var isReadyToPlay: Bool {
        guard player.state == .playing, player.isPlaying, nativeElapsed != nil else { return false }
        if hasDrawable, decodedVideoSize != nil { return true }

        // Track selection can lag the initial playing state, especially with separate HLS audio.
        guard bufferingFinished, !expectsVideo, player.videoTracks.isEmpty,
              player.media?.tracksInformation.contains(where: { $0.type == .video }) != true else { return false }
        return player.audioTracks.contains(where: \.isSelected)
    }

    private var nativeElapsed: TimeInterval? {
        guard let milliseconds = player.time.value?.doubleValue, milliseconds >= 0 else { return nil }
        return milliseconds / 1000
    }

    private var currentDuration: TimeInterval {
        let seconds = (player.media?.length.value?.doubleValue ?? 0) / 1000
        return seconds.isFinite && seconds > 0 ? seconds : duration
    }

    private func clampedTime(_ seconds: TimeInterval) -> TimeInterval {
        let length = currentDuration
        return max(0, length > 0 ? min(seconds, length) : seconds)
    }

    private func nativeTime(for seconds: TimeInterval) -> VLCTime? {
        // VLCKit converts millisecond values to native microseconds internally.
        guard let milliseconds = Int64(exactly: (seconds * 1000).rounded()),
              milliseconds <= Int64.max / 1000 else { return nil }
        return VLCTime(number: NSNumber(value: milliseconds))
    }

    private func sample() {
        if let time = nativeElapsed { elapsed = time }
        duration = currentDuration
        videoSize = decodedVideoSize ?? .zero
        isPlaying = player.isPlaying
    }

    private func publishUpdate() {
        guard state == .active, player.state == .playing || player.state == .paused else { return }
        sample()
        onEvent?(.update)
    }

    private var hasStartupPlaybackStopped: Bool {
        let playbackState = player.state
        return playbackState == .stopped || playbackState == .stopping || playbackState == .error
    }

    private func failStartup() {
        let size = player.videoSize
        startupFailureReason = "\(startupStage), state=\(player.state.rawValue), size=\(size.width)x\(size.height)"
        stop()
    }

    private func wait(in waitingState: State, until deadline: ContinuousClock.Instant, for condition: () -> Bool) async -> Bool {
        while state == waitingState && !Task.isCancelled && ContinuousClock.now < deadline {
            if waitingState == .finishing && hasStartupPlaybackStopped { return false }
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return false
            }
        }
        return false
    }

    private func handleState(_ newState: VLCMediaPlayerState) {
        if state == .preparing || state == .ready || state == .finishing {
            if newState == .error || newState == .stopping || (newState == .stopped && state != .preparing) {
                failStartup()
            }
            return
        }
        guard state == .active else { return }
        switch newState {
        case .stopped, .error:
            // This version of VLCKit reports natural EOF and unexpected stops as .stopped.
            let endTolerance = min(2, duration / 2)
            let reachedEnd = newState == .stopped && duration > 0
                && max(elapsed, nativeElapsed ?? 0) >= duration - endTolerance
            if reachedEnd { elapsed = duration }
            stop()
            onEvent?(reachedEnd ? .ended : .failed)
        case .playing, .paused:
            publishUpdate()
        default:
            break
        }
    }
}
