import CryptoKit
import Foundation
import OSLog
import PythonKit

/// Manages the pure-Python zip imported by the embedded runtime.
@available(iOS 17.0, *)
nonisolated enum YtDlpModule {
    private static let bundledVersion = "2026.11.23"
    private static let releasesURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    private static let releaseBaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download")!

    // zipimport reads the archive lazily. Freeze this choice for the life of the process
    // and never overwrite or remove a versioned archive that could be in use.
    private static let archive: URL? = {
        if let directory = try? updatesDirectory(),
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           let file = files.filter({ file in
               let version = file.deletingPathExtension().lastPathComponent
               return file.pathExtension == "zip" && isNewer(version, than: bundledVersion)
                   && version != rejectedVersion(in: directory)
           }).max(by: { isNewer($1.deletingPathExtension().lastPathComponent, than: $0.deletingPathExtension().lastPathComponent) }) {
            return file
        }
        return Bundle.main.url(forResource: "yt-dlp", withExtension: "zip")
    }()

    static func activeArchive() throws -> URL {
        guard let archive else { throw ModuleError.missingArchive }
        return archive
    }

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "YtDlpModule")

    static func load() throws -> PythonObject {
        do {
            return try importModule()
        } catch {
            let cached = try activeArchive()
            guard let bundled = Bundle.main.url(forResource: "yt-dlp", withExtension: "zip"),
                  bundled != cached else { throw error }

            try switchToBundledArchive(bundled, replacing: cached)
            let fallback = try importModule()
            let version = cached.deletingPathExtension().lastPathComponent
            try? Data(version.utf8).write(to: rejectedVersionURL(in: cached.deletingLastPathComponent()), options: .atomic)
            try? FileManager.default.removeItem(at: cached)
            log.notice("Recovered from a failed yt-dlp update with the bundled release")
            return fallback
        }
    }

    private static func importModule() throws -> PythonObject {
        try PythonJSBridge.install()
        return try Python.attemptImport("yt_dlp")
    }

    private static func switchToBundledArchive(_ bundled: URL, replacing cached: URL) throws {
        let builtins = try Python.attemptImport("builtins")
        let namespace = PythonObject(["cached": cached.path, "bundled": bundled.path])
        try builtins.exec.throwing.dynamicallyCall(withArguments: """
        import builtins
        import importlib
        import sys

        if cached in sys.path:
            sys.path.remove(cached)
        sys.path.insert(0, bundled)
        for name in tuple(sys.modules):
            if name == 'yt_dlp' or name.startswith('yt_dlp.'):
                del sys.modules[name]
        if hasattr(builtins, '__ft_js_bridge_installed__'):
            del builtins.__ft_js_bridge_installed__
        importlib.invalidate_caches()
        """, namespace)
    }

    static func runtimeVersions() throws -> (python: String, ytDlp: String) {
        let sys = try Python.attemptImport("sys")
        _ = try Python.attemptImport("ssl")
        _ = try load()
        let version = try Python.attemptImport("yt_dlp.version")
        guard let python = String(sys.version), let ytDlp = String(version.__version__) else {
            throw ModuleError.invalidArchive
        }
        return (python, ytDlp)
    }

    struct Release: Decodable, Sendable {
        let tag_name: String
        let assets: [Asset]
    }

    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let digest: String?
        let size: Int
    }

    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: releasesURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ModuleError.unavailableRelease
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard versionParts(release.tag_name) != nil else { throw ModuleError.unavailableRelease }
        return release
    }

    static func download(_ release: Release) async throws -> Data {
        let url = releaseBaseURL.appendingPathComponent(release.tag_name).appendingPathComponent("yt-dlp")
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp" }),
              asset.browser_download_url == url,
              let digest = asset.digest,
              digest.hasPrefix("sha256:") else {
            throw ModuleError.unavailableRelease
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 60))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == asset.size else {
            throw ModuleError.unavailableRelease
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == "sha256:\(hash)" else { throw ModuleError.invalidArchive }
        return data
    }

    /// Called on PythonRunner. Inspect the zip without importing downloaded code, then
    /// atomically publish it under a version-specific name for the next launch.
    static func stage(_ data: Data, version: String) throws {
        guard versionParts(version) != nil else { throw ModuleError.invalidArchive }
        let directory = try updatesDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard version != rejectedVersion(in: directory) else { throw ModuleError.incompatibleArchive }
        let destination = directory.appendingPathComponent(version).appendingPathExtension("zip")
        if FileManager.default.fileExists(atPath: destination.path) { return }
        let candidate = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: candidate) }
        try data.write(to: candidate, options: .atomic)
        try validateArchive(at: candidate, version: version)
        try FileManager.default.moveItem(at: candidate, to: destination)

        // Retain only the staged release and any archive the active interpreter may still read.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "zip"
                && versionParts(file.deletingPathExtension().lastPathComponent) != nil
                && file != archive && file != destination {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func rejectedVersion(in directory: URL) -> String? {
        try? String(contentsOf: rejectedVersionURL(in: directory), encoding: .utf8)
    }

    private static func rejectedVersionURL(in directory: URL) -> URL {
        directory.appendingPathComponent("rejected-version.txt")
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = versionParts(candidate), let current = versionParts(current) else { return false }
        return current.lexicographicallyPrecedes(candidate)
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard fields.count == 3, numbers.count == 3,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              numbers[0] >= 2020, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
        return numbers
    }

    private static func updatesDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return appSupport.appendingPathComponent("yt-dlp-updates", isDirectory: true)
    }

    private static func validateArchive(at url: URL, version: String) throws {
        let zipfile = try Python.attemptImport("zipfile")
        let file = try zipfile.ZipFile.throwing.dynamicallyCall(withArguments: url.path)
        defer { _ = try? file.close.throwing.dynamicallyCall(withArguments: []) }
        let rawVersion = try file.read.throwing.dynamicallyCall(withArguments: "yt_dlp/version.py")
        let rawInit = try file.read.throwing.dynamicallyCall(withArguments: "yt_dlp/__init__.py")
        guard let versionSource = String(try rawVersion.decode.throwing.dynamicallyCall(withArguments: "utf-8")),
              versionSource.split(whereSeparator: \.isNewline).contains("__version__ = '\(version)'"),
              let initSource = String(try rawInit.decode.throwing.dynamicallyCall(withArguments: "utf-8")) else {
            throw ModuleError.invalidArchive
        }
        let matcher = try NSRegularExpression(pattern: #"(?m)^if sys\.version_info < \(([0-9]+),\s*([0-9]+)\):"#)
        guard let match = matcher.firstMatch(in: initSource, range: NSRange(initSource.startIndex..., in: initSource)),
              let majorMatch = Range(match.range(at: 1), in: initSource),
              let minorMatch = Range(match.range(at: 2), in: initSource),
              let major = Int(initSource[majorMatch]),
              let minor = Int(initSource[minorMatch]) else {
            throw ModuleError.invalidArchive
        }
        let runtime = try Python.attemptImport("sys").version_info
        guard let runtimeMajor = Int(runtime.major), let runtimeMinor = Int(runtime.minor),
              ![runtimeMajor, runtimeMinor].lexicographicallyPrecedes([major, minor]) else {
            throw ModuleError.incompatiblePython
        }
    }

    enum ModuleError: LocalizedError {
        case missingArchive
        case invalidArchive
        case incompatiblePython
        case incompatibleArchive
        case unavailableRelease

        var errorDescription: String? {
            switch self {
            case .missingArchive: "The bundled yt-dlp archive is missing."
            case .invalidArchive: "The yt-dlp release could not be verified."
            case .incompatiblePython: "The latest yt-dlp requires a newer version of Python."
            case .incompatibleArchive: "This yt-dlp release failed to load. Using the bundled release."
            case .unavailableRelease: "The official yt-dlp release could not be downloaded."
            }
        }
    }
}
