import SwiftUI
import SwiftData
import UIKit
import OSLog

/// Reusable trailing ellipsis Menu for `Video` items. Used by search results, history,
/// the playback queue, and anywhere else a video appears in a list. Owns its own favorites
/// `@Query`, share-file sheet, and add-to-playlist sheet so callers just drop it in next to
/// the row's main tap target.
///
/// Auth-gating rules (per product spec):
///   - Open in browser, Copy URL: always shown
///   - Open in… : shown only when the video has a local downloaded file
///   - Download: shown when the video has no local downloaded file
///   - Add to favorites / Remove from favorites: shown only when signed in
///   - Add to playlist: shown only when signed in
///   - Remove downloaded file: shown only when the video has a local downloaded file
@available(iOS 17.0, *)
struct VideoMoreActionsMenu: View {
    let video: Video

    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteVideo]

    @State private var shareFileURL: URL?
    @State private var addToPlaylistVideo: Video?
    @State private var downloadError: ErrorState?

    var body: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same UIActivityViewController bridge the full-screen player uses for "Open in…".
        // ShareLink would serialize `file://` URLs as plain text inside a Menu and lose the
        // mp4 UTType, so the system share sheet wouldn't show the apps that can handle it.
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ActivityShareSheet(activityItems: [url])
            }
        }
        .sheet(item: $addToPlaylistVideo) { video in
            AddToPlaylistSheet(videoID: video.id, videoTitle: video.title)
        }
        .alert("Download", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        ), presenting: downloadError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        let localFile = DownloadManager.shared.localFile(for: video.id)
        Button {
            if let url = watchURL { UIApplication.shared.open(url) }
        } label: {
            Label("Open in browser", systemImage: "safari")
        }
        if let localFile {
            Button {
                shareFileURL = localFile
            } label: {
                Label("Open in…", systemImage: "square.and.arrow.up")
            }
        } else {
            VideoDownloadMenuButton(video: video) { downloadError = $0 }
        }
        Button {
            if let url = watchURL { UIPasteboard.general.string = url.absoluteString }
        } label: {
            Label("Copy URL", systemImage: "link")
        }
        if isSignedIn {
            Divider()
            Button {
                toggleFavorite()
            } label: {
                if isFavorite {
                    Label("Remove from favorites", systemImage: "hand.thumbsup.fill")
                } else {
                    Label("Add to favorites", systemImage: "hand.thumbsup")
                }
            }
            Button {
                addToPlaylistVideo = video
            } label: {
                Label("Add to playlist", systemImage: "text.badge.plus")
            }
        }
        if localFile != nil {
            Divider()
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownloaded(videoID: video.id, context: modelContext)
            } label: {
                Label("Remove downloaded file", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(video.id)")
    }

    private var isSignedIn: Bool {
        if case .loggedIn = AuthState.shared.status { return true }
        return false
    }

    private var isFavorite: Bool {
        favorites.contains { $0.videoID == video.id }
    }

    /// Toggles the local favorite + (when signed in) fires the YouTube like/unlike sync.
    /// Mirrors `FullScreenPlayer.toggleFavorite` so the behaviour is identical wherever the
    /// menu appears.
    private func toggleFavorite() {
        let wasFavorite = isFavorite
        if wasFavorite {
            for existing in favorites where existing.videoID == video.id {
                modelContext.delete(existing)
            }
        } else {
            modelContext.insert(FavoriteVideo(
                videoID: video.id,
                title: video.title,
                channelName: video.channelName,
                thumbnailURL: video.thumbnailURL
            ))
        }
        try? modelContext.save()

        if isSignedIn {
            let log = AppLog(subsystem: "com.leshko.freetube", category: "VideoMoreActionsMenu")
            Task { [videoID = video.id] in
                do {
                    let actions: any VideoActionsServicing = VideoActionsService()
                    if wasFavorite {
                        try await actions.removeRating(videoID: videoID)
                    } else {
                        try await actions.like(videoID: videoID)
                    }
                } catch {
                    log.error("[favorites] YouTube sync failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}

@available(iOS 17.0, *)
struct VideoDownloadMenuButton: View {
    let video: Video
    let onError: (ErrorState) -> Void

    var body: some View {
        let downloads = DownloadManager.shared
        let isDownloading = downloads.isDownloading(videoID: video.id)
        Button {
            Task {
                do {
                    _ = try await downloads.ensureDownloaded(video: video, priority: .userInitiated)
                } catch is CancellationError {
                    return
                } catch {
                    onError(ErrorState(from: error))
                }
            }
        } label: {
            if isDownloading {
                Label("Downloading · see Downloads tab", systemImage: "arrow.down.circle")
            } else {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .disabled(isDownloading)
    }
}
