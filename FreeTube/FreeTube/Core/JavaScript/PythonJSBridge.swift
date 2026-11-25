import Foundation
import OSLog
import PythonKit

/// Runs the bundled yt-dlp solver scripts in JavaScriptCore.
@available(iOS 17.0, *)
nonisolated enum PythonJSBridge {
    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "JSBridge")

    /// Identifies the in-process JavaScript adapter to the yt-dlp Deno provider.
    static let fakeDenoPath = "/dev/null/freetube-deno"

    /// Install the shim before importing yt-dlp, which subclasses subprocess.Popen at import.
    static func install() throws {
        let builtins = try Python.attemptImport("builtins")
        guard builtins.checking.__ft_js_bridge_installed__ == nil else { return }

        installEvalJSBuiltin(builtins: builtins)
        try installEJSPackageShim(builtins: builtins)
        try runPython(
            popenAdapterPython.replacingOccurrences(of: "__FAKE_DENO_PATH__", with: "'\(fakeDenoPath)'"),
            builtins: builtins
        )
        try runPython(runtimeStubPython, builtins: builtins)
        builtins.__ft_js_bridge_installed__ = true
        log.info("JavaScriptCore adapter installed")
    }

    private static func runPython(_ script: String, builtins: PythonObject) throws {
        let namespace = builtins.dict()
        try builtins.exec.throwing.dynamicallyCall(withArguments: script, namespace)
    }

    // MARK: - 1. eval_js builtin

    /// Installs `builtins.eval_js(code: str) -> str`.
    ///
    /// Wraps the caller's JS source in a prologue that captures `console.log` to an array
    /// and a trailing expression that joins the captures — this lets yt-dlp's solver code
    /// (which writes its JSON result via `console.log(JSON.stringify(...))`) work without
    /// modification. `JSContext` doesn't ship a `console` global, so the prologue defines
    /// one inside the evaluation scope.
    private static func installEvalJSBuiltin(builtins: PythonObject) {
        let evalJS = PythonFunction { (argument: PythonObject) -> PythonConvertible in
            guard let code = String(argument) else {
                let builtins = Python.import("builtins")
                let err = builtins.TypeError("eval_js: first argument must be a string")
                throw PythonError.exception(err, traceback: nil)
            }

            let wrapped = wrapForStdoutCapture(code)
            do {
                let result = try JSEvaluator.evaluate(wrapped)
                return PythonObject(result)
            } catch {
                let builtins = Python.import("builtins")
                let err = builtins.RuntimeError("eval_js: \(String(describing: error))")
                throw PythonError.exception(err, traceback: nil)
            }
        }
        builtins.eval_js = evalJS.pythonObject
    }

    /// Wraps yt-dlp's stdin-style JS payload in an IIFE that:
    ///   - defines a fake `console` that pushes log args to an array,
    ///   - executes the user code in the same scope (so top-level `var` declarations from
    ///     `lib.min.js` and `core.min.js` are visible to each other and to the trailing
    ///     `console.log` call yt-dlp appends),
    ///   - returns the joined captured output as the IIFE result.
    ///
    /// The trailing newline before `})()` matters: `core.min.js` ends without a trailing
    /// newline and yt-dlp's payload glues scripts with newlines, so we mirror that.
    private static func wrapForStdoutCapture(_ userCode: String) -> String {
        return """
        ;(function() {
            var __ftStdout = [];
            var console = {
                log: function() {
                    var parts = Array.prototype.map.call(arguments, function(a) { return String(a); });
                    __ftStdout.push(parts.join(' '));
                },
                error: function() {}, warn: function() {}, info: function() {}, debug: function() {}
            };
        \(userCode)
            return __ftStdout.join('\\n');
        })()
        """
    }

    // MARK: - 2. yt_dlp_ejs package shim

    private static func installEJSPackageShim(builtins: PythonObject) throws {
        builtins.__ft_ejs_core_js__ = PythonObject(try EJSResources.core())
        builtins.__ft_ejs_lib_js__ = PythonObject(try EJSResources.lib())
        builtins.__ft_ejs_version__ = PythonObject(EJSResources.version)
        try runPython(ejsPackageShimPython, builtins: builtins)
    }

    private static let ejsPackageShimPython = """
    import sys
    import types
    import builtins

    # Idempotency: if already installed, just refresh content (in case of version bump).
    _existing = sys.modules.get('yt_dlp_ejs')
    if _existing is None or not hasattr(_existing, '_freetube_shim'):
        _ejs = types.ModuleType('yt_dlp_ejs')
        _ejs.__path__ = []  # marks it as a package so submodule imports resolve
        _ejs._freetube_shim = True
        _ejs.version = builtins.__ft_ejs_version__
        _ejs.__version__ = builtins.__ft_ejs_version__

        _ejs_yt = types.ModuleType('yt_dlp_ejs.yt')
        _ejs_yt.__path__ = []
        _ejs.yt = _ejs_yt

        _ejs_solver = types.ModuleType('yt_dlp_ejs.yt.solver')

        def _core():
            return builtins.__ft_ejs_core_js__

        def _lib():
            return builtins.__ft_ejs_lib_js__

        _ejs_solver.core = _core
        _ejs_solver.lib = _lib
        _ejs_yt.solver = _ejs_solver

        sys.modules['yt_dlp_ejs'] = _ejs
        sys.modules['yt_dlp_ejs.yt'] = _ejs_yt
        sys.modules['yt_dlp_ejs.yt.solver'] = _ejs_solver

    # If yt_dlp.dependencies was imported BEFORE our shim landed, its `yt_dlp_ejs`
    # attribute was set to `None` by the `except ImportError: yt_dlp_ejs = None` path.
    # Rebind it so existing `from yt_dlp.dependencies import yt_dlp_ejs as _has_ejs`
    # readers see truthy on next attribute access. (For modules that already imported
    # via `from ... import yt_dlp_ejs`, the local name is frozen — but those modules
    # haven't been loaded yet at this point in our flow.)
    _yt_dlp_deps = sys.modules.get('yt_dlp.dependencies')
    if _yt_dlp_deps is not None:
        _yt_dlp_deps.yt_dlp_ejs = sys.modules['yt_dlp_ejs']
    """

    // MARK: - 3. DenoJsRuntime info stub

    private static let runtimeStubPython = """
    from yt_dlp.utils._jsruntime import DenoJsRuntime, JsRuntimeInfo

    def _freetube_deno_info(self):
        version = DenoJsRuntime.MIN_SUPPORTED_VERSION
        return JsRuntimeInfo(
            name='deno', path=self._path,
            version='.'.join(map(str, version)), version_tuple=version,
            supported=True,
        )

    DenoJsRuntime._info = _freetube_deno_info
    """

    private static let popenAdapterPython = """
    import builtins
    import subprocess

    _FAKE_DENO_PATH = __FAKE_DENO_PATH__
    _OriginalPopen = subprocess.Popen

    class _FreeTubePopen(_OriginalPopen):
        _freetube_adapter = True

        def __init__(self, args, *other, **kwargs):
            self._ft_deno = isinstance(args, (list, tuple)) and bool(args) and args[0] == _FAKE_DENO_PATH
            if not self._ft_deno:
                super().__init__(args, *other, **kwargs)
                return
            self.args = args
            self.returncode = None
            self.stdin = self.stdout = self.stderr = None
            self._ft_text_mode = any(kwargs.get(key) for key in ('text', 'universal_newlines', 'encoding', 'errors'))

        def communicate(self, input=None, timeout=None):
            if not self._ft_deno:
                return super().communicate(input, timeout)
            if isinstance(input, (bytes, bytearray)):
                input = input.decode('utf-8', errors='replace')
            try:
                output = builtins.eval_js(input or '')
                error = ''
                self.returncode = 0
            except Exception as exc:
                output = ''
                error = f'FreeTube JavaScriptCore adapter: {exc}'
                self.returncode = 1
            return (output, error) if self._ft_text_mode else (output.encode(), error.encode())

        def kill(self):
            if not self._ft_deno:
                super().kill()

        def wait(self, timeout=None):
            if not self._ft_deno:
                return super().wait(timeout)
            return self.returncode if self.returncode is not None else 0

        def __exit__(self, *exc):
            if not self._ft_deno:
                return super().__exit__(*exc)

    if not getattr(_OriginalPopen, '_freetube_adapter', False):
        subprocess.Popen = _FreeTubePopen
    """
}
