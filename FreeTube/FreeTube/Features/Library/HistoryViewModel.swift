import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class HistoryViewModel {
    private(set) var items: [YouTubeHistoryItem] = []
    private(set) var isLoading: Bool = false
    /// Separate flag for "load more in progress" so the row-level prefetch trigger can avoid
    /// firing duplicate continuation requests while the previous page is still en route.
    private(set) var isLoadingMore: Bool = false
    /// Continuation token from the most recent response. Nil → no more pages, the list is done.
    private(set) var continuationToken: String?
    var errorState: ErrorState?

    private let service: any HistoryServicing
    private var refreshID = UUID()

    init(service: any HistoryServicing = HistoryService()) {
        self.service = service
    }

    func load() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        refreshID = requestID
        isLoading = true
        defer {
            if refreshID == requestID { isLoading = false }
        }
        do {
            let page = try await service.fetch()
            guard !Task.isCancelled, refreshID == requestID else { return }
            items = page.items
            continuationToken = page.continuationToken
        } catch {
            guard !Task.isCancelled, refreshID == requestID else { return }
            errorState = ErrorState(from: error)
        }
    }

    /// True when more pages remain AND we're not already fetching one. The screen reads this
    /// from its row `.onAppear` to decide whether to trigger another `loadMore`.
    var canLoadMore: Bool {
        continuationToken != nil && !isLoadingMore && !isLoading
    }

    /// Appends the next history page. Dedupes concurrent callers via `isLoadingMore`.
    func loadMore() async {
        guard let token = continuationToken, canLoadMore, !Task.isCancelled else { return }
        let requestID = refreshID
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchMore(continuation: token)
            guard !Task.isCancelled, refreshID == requestID else { return }
            items.append(contentsOf: page.items)
            continuationToken = page.continuationToken
        } catch {
            guard !Task.isCancelled, refreshID == requestID else { return }
            errorState = ErrorState(from: error)
        }
    }

    func remove(_ video: Video) async {
        do {
            try await service.remove(videoID: video.id)
            items.removeAll { $0.video.id == video.id }
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
