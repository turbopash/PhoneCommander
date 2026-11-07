import AppKit

if CommandLine.arguments.contains("--selftest") { exit(runSelfTest()) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
