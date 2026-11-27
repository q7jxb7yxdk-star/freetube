import SwiftUI

@available(iOS 17.0, *)
struct HistoryScreen: View {
    let showsYouTubeHistory: Bool

    @State private var model = HistoryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlayerStateManager.self) private var player

    /// Distance from the end at which we kick off the next page. 5 keeps the next chunk warm
    /// before the user reaches the actual last row, so scrolling stays fluid.
    private let prefetchLookahead = 5

    var body: some View {
        List {
            if showsYouTubeHistory {
                youtubeHistory
            } else {
                Text("Sign in to YouTube")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .task(id: showsYouTubeHistory && scenePhase == .active) {
            if showsYouTubeHistory, scenePhase == .active { await model.load() }
        }
        .refreshable {
            if showsYouTubeHistory { await model.load() }
        }
        .errorToast(Bindable(model).errorState)
    }

    @ViewBuilder
    private var youtubeHistory: some View {
        ForEach(Array(model.items.enumerated()), id: \.element.video.id) { index, item in
            VideoRow(video: item.video, onTap: { player.load(item.video, startAt: item.startAt) }, showsMoreMenu: true)
                .disabled(model.isLoading)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await model.remove(item.video) }
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

    private func prefetchIfNeeded(currentIndex: Int) {
        guard currentIndex >= model.items.count - prefetchLookahead else { return }
        guard model.canLoadMore else { return }
        Task { await model.loadMore() }
    }
}
