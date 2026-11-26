import SwiftUI
import SwiftData

@available(iOS 17.0, *)
struct HistoryScreen: View {
    let showsYouTubeHistory: Bool

    @Query(sort: \WatchHistoryEntry.watchedAt, order: .reverse) private var localHistory: [WatchHistoryEntry]
    @State private var model = HistoryViewModel()
    @Environment(PlayerStateManager.self) private var player

    /// Distance from the end at which we kick off the next page. 5 keeps the next chunk warm
    /// before the user reaches the actual last row, so scrolling stays fluid.
    private let prefetchLookahead = 5

    var body: some View {
        List {
            Section("On this device") {
                if localHistory.isEmpty {
                    Text("No videos played yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(localHistory, id: \.videoID) { entry in
                    let video = makeVideo(from: entry)
                    VideoRow(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                }
            }

            if showsYouTubeHistory {
                Section("YouTube history") {
                    youtubeHistory
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .task(id: showsYouTubeHistory) {
            if showsYouTubeHistory { await model.load() }
        }
        .refreshable {
            if showsYouTubeHistory { await model.load() }
        }
        .errorToast(Bindable(model).errorState)
    }

    @ViewBuilder
    private var youtubeHistory: some View {
        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
            VideoRow(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await model.remove(video) }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .onAppear { prefetchIfNeeded(currentIndex: index) }
        }
        if model.continuationToken != nil {
            // Footer spinner — also acts as a fallback trigger if the prefetch lookahead
            // hasn't fired (e.g. when the list is very short).
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowSeparator(.hidden)
            .onAppear { Task { await model.loadMore() } }
        }
    }

    private func makeVideo(from entry: WatchHistoryEntry) -> Video {
        Video(
            id: entry.videoID,
            title: entry.title,
            channelID: "",
            channelName: entry.channelName,
            channelThumbnailURL: nil,
            thumbnailURL: entry.thumbnailURL,
            duration: entry.duration > 0 ? entry.duration : nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
    }

    private func prefetchIfNeeded(currentIndex: Int) {
        guard currentIndex >= model.videos.count - prefetchLookahead else { return }
        guard model.canLoadMore else { return }
        Task { await model.loadMore() }
    }
}
