import Foundation
import OSLog
import PythonKit
import os

nonisolated struct YtDlpDownloadError: LocalizedError, Sendable {
    let exitCode: Int?
    let httpStatus: Int?

    var errorDescription: String? {
        if let httpStatus {
            return "Download failed (HTTP \(httpStatus): \(HTTPURLResponse.localizedString(forStatusCode: httpStatus)))."
        }
        if let exitCode {
            return "yt-dlp could not download the video (status \(exitCode))."
        }
        return "yt-dlp did not report a download result."
    }
}

/// yt-dlp runs inside the interpreter lock held by PythonRunner.
@available(iOS 17.0, *)
nonisolated func freetube_yt_dlp(
    argv: [String],
    progress: @escaping @Sendable ([String: PythonObject]) -> Void,
    log: @escaping @Sendable (String, String) -> Void
) throws {
    let module = try YtDlpModule.load()
    let parsed = try module.parse_options.throwing.dynamicallyCall(withKeywordArguments: ["argv": argv])
    guard let options = parsed.checking.ydl_opts, let urls = parsed.checking.urls else {
        throw YtDlpModule.ModuleError.invalidArchive
    }
    let httpStatus = OSAllocatedUnfairLock(initialState: Int?.none)
    options["logger"] = try makeYtDlpLogger { level, message in
        if level == "error",
           let range = message.range(of: #"HTTP Error [45][0-9]{2}"#, options: .regularExpression),
           let status = Int(message[range].suffix(3)) {
            httpStatus.withLock { $0 = status }
        }
        log(level, message)
    }
    let report = PythonFunction { (value: PythonObject) in
        progress(Dictionary(value) ?? [:])
        return Python.None
    }
    options["progress_hooks"] = [report.pythonObject]
    options["js_runtimes"] = PythonObject(["deno": ["path": PythonJSBridge.fakeDenoPath]])

    let downloader = try module.YoutubeDL.throwing.dynamicallyCall(withArguments: options)
    let exitCode: Int?
    do {
        let result = try downloader.download.throwing.dynamicallyCall(withArguments: urls)
        exitCode = Int(result)
    } catch {
        guard let status = httpStatus.withLock({ $0 }) else { throw error }
        throw YtDlpDownloadError(exitCode: nil, httpStatus: status)
    }
    guard exitCode == 0 else {
        throw YtDlpDownloadError(exitCode: exitCode, httpStatus: httpStatus.withLock { $0 })
    }
}

/// Probes formats without downloading. The caller converts the result before leaving PythonRunner.
@available(iOS 17.0, *)
nonisolated func freetube_yt_dlp_extract_info(
    url: String, useVisionOSClient: Bool = false, forSubtitles: Bool = false
) throws -> PythonObject {
    let module = try YtDlpModule.load()
    let log = AppLog(subsystem: "com.leshko.freetube", category: "ytdlp")
    let youtubeOptions = useVisionOSClient
        ? ["player_client=visionos"]
        : ["player_client=tv_simply,tv_embedded,web_creator,mweb,web_safari,ios,android_vr", "formats=missing_pot"]
    let options = PythonObject([
        "verbose": true.pythonObject,
        "noplaylist": true.pythonObject,
        "nocheckcertificate": true.pythonObject,
        "socket_timeout": 30.0.pythonObject,
        "extractor_args": PythonObject(["youtube": youtubeOptions]),
        "js_runtimes": PythonObject(["deno": ["path": PythonJSBridge.fakeDenoPath]]),
        // FFmpeg runs in Swift, so skip yt-dlp's subprocess probe.
        "ffmpeg_location": "/dev/null/no-ffmpeg".pythonObject,
    ])
    if forSubtitles {
        // Use yt-dlp's default YouTube clients for caption discovery. The playback
        // clients prioritize stream formats and may omit usable caption URLs.
        options["extractor_args"] = PythonObject([String: [String]]())
        options["writesubtitles"] = true
        options["writeautomaticsub"] = true
        options["ignore_no_formats_error"] = true
        options["socket_timeout"] = 10
        options["retries"] = 0
        options["extractor_retries"] = 0
    }
    options["logger"] = try makeYtDlpLogger { level, message in
        switch level {
        case "error": log.error("\(message, privacy: .public)")
        case "warning": log.notice("\(message, privacy: .public)")
        default: log.debug("\(message, privacy: .public)")
        }
    }
    let downloader = try module.YoutubeDL.throwing.dynamicallyCall(withArguments: options)
    return try downloader.extract_info.throwing.dynamicallyCall(withArguments: url, false)
}

private nonisolated func makeYtDlpLogger(
    _ log: @escaping @Sendable (String, String) -> Void
) throws -> PythonObject {
    // yt-dlp uses the logger as a cache key when checking terminal capabilities.
    let logging = try Python.attemptImport("logging")
    let logger = try logging.Logger.throwing.dynamicallyCall(withArguments: "freetube.ytdlp")
    for level in ["debug", "info", "warning", "error"] {
        let emit = PythonFunction { (value: PythonObject) in
            let message = String(value) ?? ""
            let actualLevel = level == "debug" && !message.hasPrefix("[debug] ") ? "info" : level
            log(actualLevel, message)
            return Python.None
        }
        logger[dynamicMember: level] = emit.pythonObject
    }
    return logger
}
