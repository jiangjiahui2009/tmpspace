import AppKit

// When built by SPM (swift build), TmpspaceSettings is available as a linked
// module. When built by Xcode (which only compiles the stub for code signing),
// the module is absent — fall back to plain NSApplicationMain.
#if canImport(TmpspaceSettings)
import TmpspaceSettings

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#else
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
#endif
