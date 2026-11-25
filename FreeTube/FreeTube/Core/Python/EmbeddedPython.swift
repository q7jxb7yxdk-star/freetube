import Foundation
import PythonKit

nonisolated enum EmbeddedPython {
    private static let libraryConfigured: Bool = {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return false }
        PythonLibrary.useLibrary(at: frameworks.appending(path: "Python.framework/Python").path)
        return true
    }()

    /// The caller performs all Python work synchronously so acquired thread state stays valid.
    static func withInterpreter<T>(moduleURL: URL, _ operation: () throws -> T) throws -> T {
        guard libraryConfigured, let resources = Bundle.main.resourceURL else {
            throw InitializationError(message: "The embedded Python framework could not be located.")
        }

        let home = resources.appending(path: "python", directoryHint: .isDirectory)
        var error = [CChar](repeating: 0, count: 512)
        let result = FreeTubePythonInitialize(home.path, moduleURL.path, &error, error.count)
        guard result == 0 else {
            let message = String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            throw InitializationError(message: message)
        }

        let state = FreeTubePythonAcquireGIL()
        defer { FreeTubePythonReleaseGIL(state) }
        return try operation()
    }

    private struct InitializationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
