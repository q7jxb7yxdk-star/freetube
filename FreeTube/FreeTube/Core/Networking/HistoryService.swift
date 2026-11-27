import Foundation
import OSLog
import YouTubeKit

struct YouTubeHistoryItem: Sendable {
    let video: Video
    let startAt: TimeInterval

    nonisolated init(_ video: YTVideo) {
        self.video = Mappers.video(from: video)
        startAt = TimeInterval(video.startTime ?? 0)
    }
}

struct WatchHistoryPage: Sendable {
    let items: [YouTubeHistoryItem]
    let continuationToken: String?
}

protocol HistoryServicing: Sendable {
    func fetch() async throws -> WatchHistoryPage
    func fetchMore(continuation: String) async throws -> WatchHistoryPage
    func remove(videoID: String) async throws
}

/// Wraps `HistoryResponse` (groups videos by date) and `RemoveVideoFromHistroryResponse`. The
/// raw response splits videos into `HistoryBlock`s keyed by a localized date string; we flatten
/// them into a single list here. Day groupings are still available in the response if a
/// future UI needs them, but the current `HistoryScreen` just shows a flat list.
final class HistoryService: HistoryServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HistoryService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetch() async throws -> WatchHistoryPage {
        if #available(iOS 17.0, *) {
            await WatchHistorySyncService.shared.waitForPendingProgress()
        }
        try Task.checkCancellation()
        log.info("Fetching watch history")
        let model: YouTubeModel
        #if DEBUG
        let probe = HistoryResponseProbe()
        model = YouTubeModel()
        model.selectedLocale = client.model.selectedLocale
        model.cookies = client.model.cookies
        model.alwaysUseCookies = client.model.alwaysUseCookies
        model.visitorData = client.model.visitorData
        model.customHeaders[.historyHeaders] = client.model.getHeaders(forType: .historyHeaders)
        model.logger = probe
        var parsedMatch: Bool?
        defer {
            let raw = probe.rawMatch.map { String($0) } ?? "unavailable"
            let parsed = parsedMatch.map { String($0) } ?? "unavailable"
            log.info("History probe first page raw=\(raw, privacy: .public) parsed=\(parsed, privacy: .public)")
        }
        #else
        model = client.model
        #endif

        let response: HistoryResponse
        do {
            response = try await HistoryResponse.sendThrowingRequest(
                youtubeModel: model,
                data: [:]
            )
        } catch {
            log.error("HistoryResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            throw YouTubeServiceError.notAuthenticated
        }
        let items = flatten(response.results)
        #if DEBUG
        parsedMatch = items.contains { $0.video.id == HistoryResponseProbe.videoID }
        #endif
        return WatchHistoryPage(items: items, continuationToken: response.continuationToken)
    }

    func fetchMore(continuation: String) async throws -> WatchHistoryPage {
        let response: HistoryResponse.Continuation
        do {
            response = try await HistoryResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
        } catch {
            throw YouTubeServiceError.network(error)
        }
        return WatchHistoryPage(
            items: flatten(response.results),
            continuationToken: response.continuationToken
        )
    }

    func remove(videoID: String) async throws {
        log.info("Remove from history \(videoID, privacy: .public) — not implemented (needs suppress token)")
        throw YouTubeServiceError.notAuthenticated
    }

    /// Flattens `HistoryBlock` groups into a single list, preserving the response's
    /// newest-first ordering of videos and Shorts.
    private func flatten(_ blocks: [HistoryResponse.HistoryBlock]) -> [YouTubeHistoryItem] {
        var out: [YouTubeHistoryItem] = []
        for block in blocks {
            for entry in block.contentsArray {
                switch entry {
                case let video as HistoryResponse.HistoryBlock.VideoWithToken:
                    out.append(YouTubeHistoryItem(video.video))
                case let group as HistoryResponse.HistoryBlock.ShortsBlock:
                    out.append(contentsOf: group.shorts.map(YouTubeHistoryItem.init))
                default:
                    break
                }
            }
        }
        return out
    }
}

#if DEBUG
/// Captures one match from the History request without retaining request or response data.
private nonisolated final class HistoryResponseProbe: RequestsLogger, @unchecked Sendable {
    static let videoID = "LXPQE8cnhXU"
    private static let quotedVideoID = Data("\"\(videoID)\"".utf8)

    var logs: [any GenericRequestLog] = []
    var isLogging = true
    var maximumCacheSize: Int? = 0
    var loggedTypes: [any YouTubeResponse.Type]?

    private let lock = NSLock()
    private var match: Bool?

    var rawMatch: Bool? { lock.withLock { match } }

    func addLog(_ log: any GenericRequestLog) {
        let containsID = log.responseData.map { $0.range(of: Self.quotedVideoID) != nil }
        lock.withLock { match = containsID }
    }
}
#endif
