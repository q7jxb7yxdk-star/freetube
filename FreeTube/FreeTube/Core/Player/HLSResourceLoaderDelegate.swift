import Foundation
import AVFoundation
import OSLog
import UniformTypeIdentifiers

/// `AVAssetResourceLoaderDelegate` that proxies every HLS request (manifest + variant playlists +
/// every .ts/.mp4 segment) through a `URLSession` we control, so we can attach a consistent
/// `User-Agent` (and any other headers) to *all* of them.
///
/// Why this exists: `AVURLAssetHTTPHeaderFieldsKey` only applies to the initial manifest request.
/// `AVPlayer`'s internal URLSession issues segment requests with the system default UA
/// (`AppleCoreMedia/…`). YouTube's CDN signs the HLS playlist for a specific UA/IP, so a UA
/// mismatch between manifest and segments causes every segment to 403. By routing through the
/// resource loader we put every request on the same URLSession with the same headers.
///
/// How the URL rewriting works:
/// 1. Caller turns `https://manifest.googlevideo.com/...` into `freetubehls://manifest.googlevideo.com/...`
///    via `HLSResourceLoaderDelegate.rewrite(_:)` and hands it to `AVURLAsset`.
/// 2. AVPlayer requests the custom-scheme URL → `shouldWaitForLoadingOfRequestedResource` fires.
/// 3. We restore the original `https` scheme, perform the request with our headers, parse the body.
/// 4. For `.m3u8` responses we rewrite every absolute URL in the playlist back to the custom scheme,
///    so AVPlayer's subsequent segment requests also flow through this delegate.
@available(iOS 17.0, *)
final class HLSResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "freetubehls"

    private let userAgent: String
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HLSLoader")

    init(userAgent: String) {
        self.userAgent = userAgent
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        super.init()
    }

    /// Replaces the URL's scheme with our custom one so AVPlayer routes its requests through us.
    ///
    /// IMPORTANT: this is implemented via direct string surgery, NOT via `URLComponents`. YouTube's
    /// signed `googlevideo.com` URLs encode their signature into the query string, and `URLComponents`
    /// will silently re-encode characters like `%2C` (comma) on round-trip. Any re-encoding makes the
    /// CDN's signature check fail with HTTP 403. Preserving the exact byte sequence is mandatory.
    static func rewrite(_ url: URL) -> URL? {
        let s = url.absoluteString
        if s.hasPrefix("https://") {
            return URL(string: "\(customScheme)+https://" + s.dropFirst("https://".count))
        }
        if s.hasPrefix("http://") {
            return URL(string: "\(customScheme)+http://" + s.dropFirst("http://".count))
        }
        return nil
    }

    private static func restoreScheme(_ url: URL) -> URL? {
        let s = url.absoluteString
        let httpsPrefix = "\(customScheme)+https://"
        let httpPrefix = "\(customScheme)+http://"
        if s.hasPrefix(httpsPrefix) {
            return URL(string: "https://" + s.dropFirst(httpsPrefix.count))
        }
        if s.hasPrefix(httpPrefix) {
            return URL(string: "http://" + s.dropFirst(httpPrefix.count))
        }
        return nil
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard
            let requestedURL = loadingRequest.request.url,
            requestedURL.scheme?.hasPrefix(Self.customScheme) == true,
            let realURL = Self.restoreScheme(requestedURL)
        else {
            return false
        }

        Task { await handle(loadingRequest: loadingRequest, realURL: realURL) }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // The URLSession data task will finish on its own; we just won't ship the bytes anywhere.
    }

    // MARK: - Request handling

    private func handle(loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async {
        var request = URLRequest(url: realURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        log.debug("→ GET \(realURL.absoluteString, privacy: .public)")

        // Honor any byte-range the player asked for. AVPlayer issues ranged GETs for media segments;
        // for the playlist itself we typically get an "all bytes" request.
        var rangeHeader: String?
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                if offset > 0 { rangeHeader = "bytes=\(offset)-" }
            } else {
                let length = max(dataRequest.requestedLength, 1)
                let end = offset + Int64(length) - 1
                rangeHeader = "bytes=\(offset)-\(end)"
            }
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.error("← non-HTTP response for \(realURL.absoluteString.prefix(100), privacy: .public)")
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }

            log.debug("← HTTP \(http.statusCode, privacy: .public) mime=\(http.mimeType ?? "?", privacy: .public) bytes=\(data.count, privacy: .public) range=\(rangeHeader ?? "(full)", privacy: .public) url=\(realURL.absoluteString.prefix(100), privacy: .public)")

            if http.statusCode >= 400 {
                log.error("HTTP \(http.statusCode, privacy: .public) for \(realURL.absoluteString.prefix(120), privacy: .public)")
                loadingRequest.finishLoading(with: NSError(
                    domain: "HLSLoaderHTTP",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(realURL.host ?? "?")"]
                ))
                return
            }

            let mime = http.mimeType ?? ""
            let isPlaylist = mime.contains("mpegurl") || mime.contains("m3u8")
                || realURL.path.hasSuffix(".m3u8")

            // Rewrite m3u8 contents so segment URLs in the playlist also use our custom scheme.
            // Then every segment fetch comes back to us, preserving the same UA + auth context.
            let outgoing: Data
            if isPlaylist, let text = String(data: data, encoding: .utf8) {
                outgoing = rewriteManifest(text).data(using: .utf8) ?? data
            } else {
                outgoing = data
            }

            if let contentInfo = loadingRequest.contentInformationRequest {
                contentInfo.contentType = mime
                contentInfo.isByteRangeAccessSupported = !isPlaylist
                // For ranged responses, contentLength is the FULL resource length, not the slice
                // we just received; parse from Content-Range when present.
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalString = contentRange.split(separator: "/").last,
                   let total = Int64(totalString) {
                    contentInfo.contentLength = total
                } else {
                    contentInfo.contentLength = Int64(outgoing.count)
                }
            }

            loadingRequest.dataRequest?.respond(with: outgoing)
            loadingRequest.finishLoading()
        } catch {
            log.error("Fetch failed for \(realURL.absoluteString.prefix(120), privacy: .public): \(String(describing: error), privacy: .public)")
            loadingRequest.finishLoading(with: error)
        }
    }

    /// Walks the m3u8 line-by-line, rewriting absolute URLs (both standalone lines and quoted
    /// `URI="…"` attributes inside `#EXT-X-MEDIA` / `#EXT-X-MAP` / `#EXT-X-KEY`) from `https://`
    /// to our custom scheme. Relative paths are left alone — AVPlayer resolves them against the
    /// (already rewritten) playlist's own URL, so they'll inherit the custom scheme.
    private func rewriteManifest(_ manifest: String) -> String {
        manifest.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)

            // Standalone URL line (segment or sub-playlist reference).
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                if let url = URL(string: trimmed), let rewritten = Self.rewrite(url) {
                    return rewritten.absoluteString
                }
            }

            // Tag lines that embed URIs as quoted attributes.
            if trimmed.hasPrefix("#") && trimmed.contains("URI=\"") {
                return rewriteURIAttributes(in: String(line))
            }

            return String(line)
        }
        .joined(separator: "\n")
    }

    private func rewriteURIAttributes(in line: String) -> String {
        var result = ""
        var remainder = Substring(line)
        let marker = "URI=\""
        while let markerRange = remainder.range(of: marker) {
            result.append(String(remainder[..<markerRange.upperBound]))
            remainder = remainder[markerRange.upperBound...]
            guard let closing = remainder.firstIndex(of: "\"") else {
                result.append(String(remainder))
                return result
            }
            let urlText = String(remainder[..<closing])
            if let url = URL(string: urlText), let rewritten = Self.rewrite(url) {
                result.append(rewritten.absoluteString)
            } else {
                result.append(urlText)
            }
            remainder = remainder[closing...]
        }
        result.append(String(remainder))
        return result
    }
}

/// A snapshot of the master playlist for building exact-resolution or capped adaptive assets.
nonisolated struct HLSResolutionPlaylist: Sendable {
    enum VLCCodecSelection: String, Sendable {
        case all
        case vp9
        case other
        case preferVP9
    }

    private struct Entry: Sendable {
        let text: String
        let resolution: Int?

        var isStreamVariant: Bool { text.hasPrefix("#EXT-X-STREAM-INF:") }
    }

    private struct VLCVariant {
        let entry: Entry
        let groups: [Substring: Substring]
        let isVP9: Bool
    }

    private let entries: [Entry]
    private let query: String?
    let resolutions: [Int]

    static func load(from url: URL) async throws -> HLSResolutionPlaylist {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let baseURL = http.url, baseURL.scheme?.lowercased() == "https" else {
            throw URLError(.badServerResponse)
        }
        guard let manifest = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return try HLSResolutionPlaylist(manifest: manifest, baseURL: baseURL)
    }

    @MainActor
    func makePlayback(resolution: Int) -> (asset: AVURLAsset, loader: HLSResolutionResourceLoader)? {
        guard resolutions.contains(resolution) else { return nil }
        let lines = entries.compactMap { entry in
            entry.resolution == resolution || (entry.resolution == nil && !entry.isStreamVariant) ? entry.text : nil
        }
        var urlString = "freetubehlsresolution://playlist/\(UUID().uuidString)/master.m3u8"
        // QUERYPARAM definitions in the master must also work for IMPORT tags in child playlists.
        if let query { urlString += "?" + query }
        guard let url = URL(string: urlString, encodingInvalidCharacters: false) else { return nil }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let loader = HLSResolutionResourceLoader(url: url, data: data)
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        return (asset, loader)
    }

    func vlcPlaybackData(
        resolution: Int? = nil, maximumResolution: Int? = nil, codec: VLCCodecSelection = .all
    ) -> Data? {
        // VLC's local master cannot supply variables that a child playlist imports.
        guard !entries.contains(where: { $0.text.hasPrefix("#EXT-X-DEFINE:") }) else {
            return nil
        }
        let whitelist: Set<Int>?
        if let resolution {
            guard resolutions.contains(resolution), resolution <= (maximumResolution ?? resolution) else { return nil }
            whitelist = [resolution]
        } else if let maximumResolution {
            whitelist = Set(resolutions.filter { $0 <= maximumResolution })
        } else {
            whitelist = nil
        }

        let renditionTypes: Set<Substring> = ["AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS"]
        let renditions = entries.compactMap { entry -> (type: Substring, group: Substring, line: String, isSupported: Bool)? in
            guard entry.text.hasPrefix("#EXT-X-MEDIA:") else { return nil }
            let attributes = Self.attributes(in: entry.text)
            guard let type = attributes["TYPE"], renditionTypes.contains(type), let group = attributes["GROUP-ID"] else {
                return nil
            }
            return (type, group, entry.text, Self.hasHTTPSURI(in: attributes))
        }
        let groupsByType = Dictionary(grouping: renditions, by: \.type)
            .mapValues { Dictionary(grouping: $0, by: \.group) }
        var variants: [VLCVariant] = []
        for entry in entries where entry.isStreamVariant {
            if let whitelist {
                guard let size = entry.resolution, whitelist.contains(size) else { continue }
            }
            guard let tag = entry.text.split(separator: "\n", maxSplits: 1).first else { continue }
            let attributes = Self.attributes(in: String(tag))
            let groups = attributes.filter { type, group in
                renditionTypes.contains(type) && !(type == "CLOSED-CAPTIONS" && group == "NONE")
            }
            guard groups.allSatisfy({ type, group in
                groupsByType[type]?[group]?.allSatisfy(\.isSupported) == true
            }) else { continue }
            let isVP9 = attributes["CODECS"]?.split(separator: ",").contains { codec in
                let name = codec.trimmingCharacters(in: .whitespaces).lowercased()
                return name == "vp9" || name == "vp09" || name.hasPrefix("vp9.") || name.hasPrefix("vp09.")
            } ?? false
            variants.append(VLCVariant(entry: entry, groups: groups, isVP9: isVP9))
        }

        let selected = switch codec {
        case .all:
            variants
        case .vp9:
            variants.filter { $0.isVP9 }
        case .other:
            variants.filter { !$0.isVP9 }
        case .preferVP9:
            variantsPreferringVP9(variants)
        }
        guard !selected.isEmpty else { return nil }
        // The adaptive preference only needs a local master when it changes a resolution's variants.
        if codec == .preferVP9, selected.count == variants.count { return nil }

        var selectedGroups: [Substring: Set<Substring>] = [:]
        for variant in selected {
            for (type, group) in variant.groups {
                selectedGroups[type, default: []].insert(group)
            }
        }

        // Retain the master tags needed by the selected streams. Stream and rendition URLs
        // were resolved against the final HTTPS response URL before changing to a local file.
        var headers: [String] = []
        for entry in entries {
            let line = entry.text
            if line == "#EXTM3U" || line.hasPrefix("#EXT-X-VERSION:") || line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                headers.append(line)
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                guard Self.hasHTTPSURI(in: Self.attributes(in: line)) else { return nil }
                headers.append(line)
            }
        }
        let selectedRenditions = renditions.filter { selectedGroups[$0.type]?.contains($0.group) == true }.map(\.line)
        let selectedVariants = selected.map { $0.entry.text }
        return Data(((headers + selectedRenditions + selectedVariants).joined(separator: "\n") + "\n").utf8)
    }

    private func variantsPreferringVP9(_ variants: [VLCVariant]) -> [VLCVariant] {
        let vp9Resolutions = Set(variants.compactMap { $0.isVP9 ? $0.entry.resolution : nil })
        return variants.filter { variant in
            guard !variant.isVP9, let resolution = variant.entry.resolution else { return true }
            return !vp9Resolutions.contains(resolution)
        }
    }

    private static func hasHTTPSURI(in attributes: [Substring: Substring]) -> Bool {
        guard let uri = attributes["URI"] else { return true }
        guard let url = URL(string: String(uri), encodingInvalidCharacters: false) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil
    }

    private init(manifest: String, baseURL: URL) throws {
        let lines = manifest.split(whereSeparator: \.isNewline)
        guard lines.first == "#EXTM3U" else { throw URLError(.cannotParseResponse) }

        let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        var usesQuery = false
        var variables: [String: String] = [:]
        var found: Set<Int> = []
        var parsed: [Entry] = []
        var pendingVariant: (tag: String, resolution: Int?)?

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if !line.hasPrefix("#") {
                guard let variant = pendingVariant else { throw URLError(.cannotParseResponse) }
                pendingVariant = nil
                let uri = try Self.resolveURI(line, against: baseURL, variables: variables)
                guard let url = URL(string: uri, encodingInvalidCharacters: false),
                      url.scheme?.lowercased() == "https", url.host != nil else { continue }
                if let resolution = variant.resolution { found.insert(resolution) }
                parsed.append(Entry(text: variant.tag + "\n" + uri, resolution: variant.resolution))
                continue
            }

            let tag = line.prefix { $0 != ":" }
            let attributes = Self.attributes(in: line)
            switch tag {
            case "#EXT-X-STREAM-INF":
                guard pendingVariant == nil else { throw URLError(.cannotParseResponse) }
                pendingVariant = (line, Self.resolution(from: attributes["RESOLUTION"]))
                continue
            case "#EXT-X-CONTENT-STEERING":
                // A steering manifest can replace signed variant and rendition URLs.
                continue
            case "#EXT-X-DEFINE":
                if let parameter = attributes["QUERYPARAM"] {
                    guard let value = baseComponents?.queryItems?.first(where: { $0.name == parameter })?.value else {
                        throw URLError(.cannotParseResponse)
                    }
                    variables[String(parameter)] = value
                    usesQuery = true
                } else if let name = attributes["NAME"], let value = attributes["VALUE"] {
                    variables[String(name)] = try Self.expandVariables(in: String(value), using: variables)
                }
            default:
                break
            }

            let resolution: Int?
            if tag == "#EXT-X-I-FRAME-STREAM-INF" {
                guard let size = Self.resolution(from: attributes["RESOLUTION"]) else { continue }
                resolution = size
            } else {
                resolution = nil
            }
            if let uri = attributes["URI"] {
                let absoluteURI = try Self.resolveURI(String(uri), against: baseURL, variables: variables)
                line.replaceSubrange(uri.startIndex..<uri.endIndex, with: absoluteURI)
            }
            parsed.append(Entry(text: line, resolution: resolution))
        }

        guard pendingVariant == nil, parsed.contains(where: \.isStreamVariant) else { throw URLError(.cannotParseResponse) }
        resolutions = found.sorted(by: >)
        entries = parsed
        query = usesQuery ? baseComponents?.percentEncodedQuery : nil
    }

    private static func attributes(in line: String) -> [Substring: Substring] {
        guard line.hasPrefix("#EXT-X-"), let colon = line.firstIndex(of: ":") else { return [:] }
        let list = line[line.index(after: colon)...]
        var attributes: [Substring: Substring] = [:]
        // Quoted values can contain commas, including codec lists, names, and signed URLs.
        for match in list.matches(of: #/(?:^|,)([A-Z0-9-]+)=(?:"([^"]*)"|([^,]+))/#) {
            attributes[match.1] = match.2 ?? match.3
        }
        return attributes
    }

    private static func resolution(from dimensions: Substring?) -> Int? {
        guard let parts = dimensions?.split(separator: "x", omittingEmptySubsequences: false),
              parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return nil }
        return min(width, height)
    }

    private static func expandVariables(in value: String, using variables: [String: String]) throws -> String {
        var expanded = value
        for match in value.matches(of: #/\{\$([a-zA-Z0-9_-]+)\}/#).reversed() {
            guard let replacement = variables[String(match.1)] else { throw URLError(.cannotParseResponse) }
            expanded.replaceSubrange(match.range, with: replacement)
        }
        return expanded
    }

    private static func resolveURI(_ uri: String, against baseURL: URL, variables: [String: String]) throws -> String {
        let expanded = try expandVariables(in: uri, using: variables)
        guard !expanded.isEmpty, let reference = URL(string: expanded, encodingInvalidCharacters: false) else {
            throw URLError(.badURL)
        }
        // Preserve the original spelling and percent escapes of signed absolute URLs.
        if reference.scheme != nil { return expanded }
        guard let resolved = URL(string: expanded, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        return resolved.absoluteString
    }
}

/// Serves one in-memory master. AVPlayer loads the referenced HTTPS playlists and media directly.
nonisolated final class HLSResolutionResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let url: URL
    private let data: Data

    fileprivate init(url: URL, data: Data) {
        self.url = url
        self.data = data
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url == url else { return false }

        if let content = loadingRequest.contentInformationRequest {
            let contentType = UTType.m3uPlaylist.identifier
            if content.allowedContentTypes?.contains(contentType) != false {
                content.contentType = contentType
            }
            content.contentLength = Int64(data.count)
            content.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            let requestedOffset = request.requestedOffset
            let offset = max(request.currentOffset, requestedOffset)
            guard requestedOffset >= 0, let start = Int(exactly: offset), start <= data.count else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return true
            }
            let available = data.count - start
            let length = request.requestsAllDataToEndOfResource
                ? available
                : min(max(0, request.requestedLength - (start - Int(requestedOffset))), available)
            if length > 0 {
                request.respond(with: data.subdata(in: start..<(start + length)))
            }
        }
        loadingRequest.finishLoading()
        return true
    }
}
