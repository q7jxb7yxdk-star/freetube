import Foundation
import OSLog
import PythonKit

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
    options["logger"] = try makeYtDlpLogger(log)
    let report = PythonFunction { (value: PythonObject) in
        progress(Dictionary(value) ?? [:])
        return Python.None
    }
    options["progress_hooks"] = [report.pythonObject]
    options["js_runtimes"] = PythonObject(["deno": ["path": PythonJSBridge.fakeDenoPath]])

    let downloader = try module.YoutubeDL.throwing.dynamicallyCall(withArguments: options)
    try downloader.download.throwing.dynamicallyCall(withArguments: urls)
}

/// Probes formats without downloading. The caller converts the result before leaving PythonRunner.
@available(iOS 17.0, *)
nonisolated func freetube_yt_dlp_extract_info(url: String) throws -> PythonObject {
    let module = try YtDlpModule.load()
    let log = AppLog(subsystem: "com.leshko.freetube", category: "ytdlp")
    let options = PythonObject([
        "verbose": true.pythonObject,
        "noplaylist": true.pythonObject,
        "nocheckcertificate": true.pythonObject,
        "socket_timeout": 30.0.pythonObject,
        "extractor_args": PythonObject([
            "youtube": ["player_client=tv_simply,tv_embedded,web_creator,mweb,web_safari,ios,android_vr", "formats=missing_pot"]
        ]),
        "js_runtimes": PythonObject(["deno": ["path": PythonJSBridge.fakeDenoPath]]),
        // FFmpeg runs in Swift, so skip yt-dlp's subprocess probe.
        "ffmpeg_location": "/dev/null/no-ffmpeg".pythonObject,
    ])
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
    let types = try Python.attemptImport("types")
    let logger = try types.SimpleNamespace.throwing.dynamicallyCall(withArguments: [])
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
