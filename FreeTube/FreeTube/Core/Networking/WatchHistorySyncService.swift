import Foundation
import OSLog
import YouTubeKit

/// Reports playback and measured watch time through the signed-in YouTube watch page.
@available(iOS 17.0, *)
@MainActor
final class WatchHistorySyncService {
    static let shared = WatchHistorySyncService()

    enum PlaybackState {
        case playing
        case paused
        case finished
    }

    typealias WatchTimeReporter = @MainActor (ClosedRange<TimeInterval>, PlaybackState) -> Void

    private struct ReportingSession {
        let watchTimeURL: URL
        let watchPage: URLRequest
    }

    private let client = YouTubeKitClient.shared
    private let preferences = UserPreferences()
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "WatchHistorySync")
    private let session: URLSession
    private var pendingSeek: Task<Void, Never>?
    private var pendingFinalReport: Task<Void, Never>?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func beginPlayback(videoID: String) -> WatchTimeReporter? {
        guard preferences.syncYouTubeWatchHistory else { return nil }
        guard case .loggedIn = AuthState.shared.status else {
            log.info("Skipped playback reporting because the app is signed out")
            return nil
        }

        // Snapshot the account at playback start so a switch during the fetch cannot redirect the report.
        let cookies = client.cookies
        guard !cookies.isEmpty else {
            log.notice("Skipped playback reporting because the session is missing")
            return nil
        }
        let precedingFinalReport = pendingFinalReport
        let start = Task {
            await precedingFinalReport?.value
            return await submitPlaybackStart(videoID: videoID, cookies: cookies)
        }
        var previousReport: Task<Void, Never>?
        return { segment, state in
            let previous = previousReport
            let report = Task {
                await previous?.value
                guard let reportingSession = await start.value else { return }
                await self.submitWatchTime(segment, state: state, session: reportingSession, cookies: cookies)
            }
            previousReport = report
            if state == .finished { self.pendingFinalReport = report }
        }
    }

    func prepareHistoryRefresh(after seek: Task<Void, Never>) {
        pendingSeek = seek
    }

    func waitForPendingProgress() async {
        guard preferences.syncYouTubeWatchHistory else { return }
        // The confirmed seek can enqueue a final report before it returns.
        while !Task.isCancelled {
            let seek = pendingSeek
            await seek?.value
            guard !Task.isCancelled else { return }
            let finalReport = pendingFinalReport
            await finalReport?.value
            if seek == pendingSeek, finalReport == pendingFinalReport { return }
        }
    }

    private func submitPlaybackStart(videoID: String, cookies: String) async -> ReportingSession? {
        guard canReport(using: cookies) else { return nil }
        var watchRequest = HeadersList.setHeadersAgentFor(
            content: client.model.getHeaders(forType: .videoInfos),
            data: [.query: videoID]
        )
        guard let watchURL = watchRequest.url,
              watchURL.scheme == "https",
              watchURL.host == "www.youtube.com",
              watchURL.port == nil, watchURL.user == nil, watchURL.password == nil,
              watchURL.path == "/watch",
              watchRequest.httpMethod == "GET",
              let authorization = client.model.generateSAPISIDHASHForCookies(cookies) else {
            log.notice("Could not prepare the authenticated watch page request")
            return nil
        }
        watchRequest.setValue(cookies, forHTTPHeaderField: "Cookie")
        watchRequest.setValue(authorization, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: watchRequest)
            guard accepted(response, stage: "Watch page") else { return nil }
            guard let tracking = await Self.trackingURLs(from: data, videoID: videoID) else {
                log.notice("Watch page did not return usable playback and watch-time reporting URLs")
                return nil
            }
            await sendReport(to: tracking.playback, watchPage: watchRequest, cookies: cookies, stage: "Playback start")
            return ReportingSession(watchTimeURL: tracking.watchTime, watchPage: watchRequest)
        } catch {
            log.notice("Watch page request failed with error code \((error as NSError).code, privacy: .public)")
            return nil
        }
    }

    private func submitWatchTime(
        _ segment: ClosedRange<TimeInterval>,
        state: PlaybackState,
        session: ReportingSession,
        cookies: String
    ) async {
        guard var components = URLComponents(url: session.watchTimeURL, resolvingAgainstBaseURL: false) else { return }
        let end = String(segment.upperBound)
        Self.setQueryItems([
            URLQueryItem(name: "st", value: String(segment.lowerBound)),
            URLQueryItem(name: "et", value: end),
            URLQueryItem(name: "cmt", value: end),
            URLQueryItem(name: "state", value: state == .playing ? "playing" : "paused"),
            URLQueryItem(name: "final", value: state == .finished ? "1" : "0")
        ], on: &components)
        guard let url = components.url else { return }
        let stage = "Watch time (\(state), position=\(end)s)"
        await sendReport(to: url, watchPage: session.watchPage, cookies: cookies, stage: stage)
    }

    private func sendReport(to url: URL, watchPage: URLRequest, cookies: String, stage: String) async {
        guard canReport(using: cookies),
              let authorization = client.model.generateSAPISIDHASHForCookies(cookies) else {
            log.info("\(stage, privacy: .public) skipped because synchronization or the session changed")
            return
        }
        do {
            var report = URLRequest(url: url)
            report.setValue(cookies, forHTTPHeaderField: "Cookie")
            report.setValue(authorization, forHTTPHeaderField: "Authorization")
            report.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            report.setValue(watchPage.url?.absoluteString, forHTTPHeaderField: "Referer")
            report.setValue(watchPage.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
            let (_, reportResponse) = try await session.data(for: report)
            _ = accepted(reportResponse, stage: stage)
        } catch {
            // Request URLs and errors that include them can contain signed parameters.
            log.notice("\(stage, privacy: .public) request failed with error code \((error as NSError).code, privacy: .public)")
        }
    }

    private func canReport(using cookies: String) -> Bool {
        guard preferences.syncYouTubeWatchHistory,
              case .loggedIn = AuthState.shared.status else { return false }
        return client.cookies == cookies
    }

    private func accepted(_ response: URLResponse, stage: String) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        log.notice("\(stage, privacy: .public) returned HTTP \(http.statusCode, privacy: .public)")
        return (200..<300).contains(http.statusCode)
    }

    @concurrent private static func trackingURLs(
        from data: Data,
        videoID: String
    ) async -> (playback: URL, watchTime: URL)? {
        let html = String(decoding: data, as: UTF8.self)
        guard let assignment = html.range(
            of: #"\bvar\s+ytInitialPlayerResponse\s*=\s*(?=\{)"#,
            options: .regularExpression
        ),
        let json = initialJSONObject(in: html[assignment.upperBound...]),
        let player = try? JSONDecoder().decode(WatchPagePlayback.self, from: json),
        player.videoDetails.videoId == videoID,
        player.responseContext?.mainAppWebResponseContext?.loggedOut != true,
        let tracking = player.playbackTracking,
        let playbackEndpoint = tracking.videostatsPlaybackUrl?.baseUrl,
        let watchTimeEndpoint = tracking.videostatsWatchtimeUrl?.baseUrl,
        var playback = trackingComponents(playbackEndpoint, path: "/api/stats/playback"),
        var watchTime = trackingComponents(watchTimeEndpoint, path: "/api/stats/watchtime") else { return nil }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let nonce = String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        let trackingParameters = [
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "cpn", value: nonce)
        ]
        setQueryItems(trackingParameters + [
            URLQueryItem(name: "rtn", value: "0"),
            URLQueryItem(name: "rt", value: "0")
        ], on: &playback)
        setQueryItems(trackingParameters, on: &watchTime)
        guard let playbackURL = playback.url, let watchTimeURL = watchTime.url else { return nil }
        return (playbackURL, watchTimeURL)
    }

    nonisolated private static func trackingComponents(_ endpoint: String, path: String) -> URLComponents? {
        guard var components = URLComponents(string: endpoint),
        components.scheme == "https",
        components.host == "www.youtube.com" || components.host == "s.youtube.com",
        components.port == nil, components.user == nil, components.password == nil,
        components.percentEncodedPath == path else { return nil }

        // Use the same YouTube origin as the watch page for the authenticated request.
        components.host = "www.youtube.com"
        components.fragment = nil
        return components
    }

    nonisolated private static func setQueryItems(_ items: [URLQueryItem], on components: inout URLComponents) {
        let replacedNames = Set(items.map(\.name))
        let existing = components.percentEncodedQueryItems ?? []
        components.percentEncodedQueryItems = existing.filter {
            !replacedNames.contains($0.name.removingPercentEncoding ?? $0.name)
        } + items
    }

    /// Extract the assignment's JSON object even when another statement follows it in the script.
    nonisolated private static func initialJSONObject(in source: Substring) -> Data? {
        let bytes = source.utf8
        var depth = 0
        var insideString = false
        var escaped = false

        for index in bytes.indices {
            let byte = bytes[index]
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // backslash
                    escaped = true
                } else if byte == 0x22 { // quotation mark
                    insideString = false
                }
            } else {
                switch byte {
                case 0x22: insideString = true
                case 0x7B: depth += 1 // opening brace
                case 0x7D: // closing brace
                    depth -= 1
                    if depth == 0 { return Data(bytes[..<bytes.index(after: index)]) }
                default: break
                }
            }
        }
        return nil
    }
}

private nonisolated struct WatchPagePlayback: Decodable {
    struct VideoDetails: Decodable {
        let videoId: String
    }

    struct PlaybackTracking: Decodable {
        struct Endpoint: Decodable {
            let baseUrl: String
        }
        let videostatsPlaybackUrl: Endpoint?
        let videostatsWatchtimeUrl: Endpoint?
    }

    struct ResponseContext: Decodable {
        struct WebContext: Decodable {
            let loggedOut: Bool?
        }
        let mainAppWebResponseContext: WebContext?
    }

    let videoDetails: VideoDetails
    let playbackTracking: PlaybackTracking?
    let responseContext: ResponseContext?
}

private nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
