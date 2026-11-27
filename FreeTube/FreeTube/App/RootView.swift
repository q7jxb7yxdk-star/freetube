import SwiftUI
import LNPopupUI
import Kingfisher
import UIKit

/// Top-level tabbed shell. CLAUDE.md §8: mini-player sits above the tab bar and persists across tabs.
///
/// Tab layout (5):
/// - Search (search field, recent searches, and the home video feed in one screen)
/// - Library (subsumes the former Account + Subscriptions tabs; includes Favorites/Recents/Playlists/Login)
/// - Link (yt-dlp-powered universal downloader; pastes any link from ~2,000 supported sites)
/// - Downloads (saved videos + live transfer queue with progress)
/// - Settings (preferences, quality, reset-session)
@available(iOS 17.0, *)
struct RootView: View {
    @Environment(PlayerStateManager.self) private var player
    @State private var selectedTab: Tab = .search
    @State private var popupDidOpen = false
    /// Direct observation of the shared download manager — no AsyncStream subscription needed since
    /// `DownloadManager` is itself `@Observable`. Both this view (for the badge) and `DownloadsScreen`
    /// (for the list) read the same source of truth.
    @State private var downloads = DownloadManager.shared
    /// Artwork shown while the mini-player waits for the current video.
    @State private var thumbnail: UIImage?

    enum Tab: Hashable {
        case search, library, link, downloads, settings
    }

    private var activeDownloadsCount: Int {
        downloads.activeTasks.filter { snapshot in
            switch snapshot.state {
            case .queued, .downloading, .paused: return true
            case .completed, .failed: return false
            }
        }.count
    }

    var body: some View {
        @Bindable var player = player

        TabView(selection: $selectedTab) {
            HomeScreen()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            LibraryScreen()
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(Tab.library)

            FetchScreen()
                .tabItem { Label("Link", systemImage: "link") }
                .tag(Tab.link)

            DownloadsScreen()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .badge(activeDownloadsCount > 0 ? activeDownloadsCount : 0)
                .tag(Tab.downloads)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .popup(
            isBarPresented: $player.miniPlayerVisible,
            isPopupOpen: $player.fullScreenPresented,
            // Transfer VLC after LNPopupUI finishes laying out the destination.
            onOpen: { popupDidOpen = true },
            onClose: { popupDidOpen = false }
        ) {
            PopupContentWrapper(popupDidOpen: $popupDidOpen)
        }
        .popupBarCustomView(wantsDefaultTapGesture: false) {
            MiniPlayerBar(player: player, thumbnail: $thumbnail, popupDidOpen: $popupDidOpen)
        }
        .popupInteractionStyle(UIViewController.PopupInteractionStyle.drag)
        .popupCloseButtonStyle(LNPopupCloseButton.Style.none)
        .popupBarProgressViewStyle(.bottom)
        .task {
            await SessionManager.shared.bootstrap()
        }
        // Refresh the fallback artwork whenever the user picks a new video.
        .onChange(of: player.currentVideo?.id, initial: true) {
            loadThumbnailForCurrentVideo()
        }
        // Force a light-content status bar (white glyphs) while the full-screen player is up.
        // SwiftUI's `.preferredColorScheme(.dark)` on the popup content doesn't propagate through
        // LNPopupUI's hosting chain to UIKit's status-bar style, but flipping the window's
        // `overrideUserInterfaceStyle = .dark` does — UIKit recomputes the status bar trait from
        // that, gets `.dark`, and switches the bar to light content. We restore `.unspecified` when
        // the popup collapses so the rest of the app honors the system appearance again.
        .onChange(of: player.fullScreenPresented) { _, presented in
            updateStatusBarOverride(forFullScreenOpen: presented)
        }
        .onChange(of: player.miniPlayerVisible) { _, visible in
            if !visible { popupDidOpen = false }
        }
        // Menu-bar / keyboard-shortcut driven tab switching from `MacCommands`. The
        // notification is meaningful only on Mac (where the menu bar exists) and on iPad
        // with a hardware keyboard; everywhere else nobody posts it and this is a no-op.
        .onReceive(NotificationCenter.default.publisher(for: .freetubeSelectTab)) { note in
            if let tab = note.object as? Tab {
                selectedTab = tab
            }
        }
    }

    private func updateStatusBarOverride(forFullScreenOpen open: Bool) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        window?.overrideUserInterfaceStyle = open ? .dark : .unspecified
    }

    /// Refreshes `thumbnail` whenever the current video changes. Tries three sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flash).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the `Video` object the screen built has `thumbnailURL == nil`).
    ///  3. Async Kingfisher fetch from disk/network if neither of the above hit.
    /// Clears `thumbnail` immediately first so we don't show the previous video's preview while
    /// the new one is loading.
    private func loadThumbnailForCurrentVideo() {
        thumbnail = nil

        guard let video = player.currentVideo else { return }

        // 1. Synchronous in-memory cache for the thumbnail URL.
        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            thumbnail = cached
            return
        }

        // 2. Xattr-stored thumbnail for downloaded videos. `DownloadsStore` keeps the
        // current snapshot in memory, so the lookup is synchronous and the compressed JPEG
        // bytes decode straight to a `UIImage`.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            self.thumbnail = image
            return
        }

        // 3. Async network/disk-cache fetch (in parallel with the xattr lookup above —
        // whichever completes first and matches the current video wins).
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                // Guard against a race: if the user has already switched to another video while
                // this fetch was inflight, don't stomp the new thumbnail with the stale one.
                guard self.player.currentVideo?.id == videoID else { return }
                self.thumbnail = value.image
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MiniPlayerBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let player: PlayerStateManager
    @Binding var thumbnail: UIImage?
    @Binding var popupDidOpen: Bool

    private var maximumPreviewWidth: CGFloat {
        horizontalSizeClass == .regular ? 192 : 160
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(maximumPreviewWidth, geometry.size.width * 0.43)
            HStack(spacing: 4) {
                Button {
                    player.fullScreenPresented = true
                } label: {
                    HStack(spacing: 8) {
                        preview
                            .frame(width: width, height: width * 9 / 16)
                            .clipShape(.rect(cornerRadius: 8))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.currentVideo?.title ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            subtitle
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))

                Button {
                    player.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Next"))
            }
            .buttonStyle(.plain)
        }
        .frame(height: maximumPreviewWidth * 9 / 16 + 8)
        .padding(.horizontal, 8)
    }

    private var preview: some View {
        ZStack {
            Color.black
            if !popupDidOpen, player.vlcPlayback != nil || player.stagedVLCPlayback != nil {
                VLCKitSurface(
                    activeDrawable: player.vlcPlayback?.drawable,
                    stagedDrawable: player.stagedVLCPlayback?.drawable,
                    isCurrentHost: { !popupDidOpen },
                    canStartPlayback: { [weak player] in player?.fullScreenPresented == false }
                )
                .allowsHitTesting(false)

                // Lay out the staged drawable behind the artwork so it can start decoding.
                if player.vlcPlayback == nil {
                    Color.black
                    artwork
                }
            } else {
                artwork
                if !popupDidOpen, player.loadState == .readyToPlay, !player.isExternalPlaybackActive {
                    InlinePlayerSurface(player: player.player)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var subtitle: Text {
        switch player.loadState {
        case .resolving:
            Text("Preparing…")
        case .failed(let message):
            Text(message)
        case .idle, .readyToPlay:
            Text(player.currentVideo?.channelName ?? "")
        }
    }
}

@available(iOS 17.0, *)
private struct PopupContentWrapper: View {
    @Environment(PlayerStateManager.self) private var player
    @Binding var popupDidOpen: Bool
    // Mirror progress in state so LNPopupUI receives a fresh preference as playback advances.
    @State private var progress: Float = 0

    var body: some View {
        FullScreenPlayer(popupDidOpen: $popupDidOpen)
            .popupProgress(progress)
            .onChange(of: player.elapsed, initial: true) { _, _ in refreshProgress() }
            .onChange(of: player.duration) { _, _ in refreshProgress() }
            .onChange(of: player.loadState) { _, _ in refreshProgress() }
    }

    private func refreshProgress() {
        let next = player.duration > 0 ? Float(min(1, max(0, player.elapsed / player.duration))) : 0
        if abs(next - progress) > 0.001 {
            progress = next
        }
    }
}
