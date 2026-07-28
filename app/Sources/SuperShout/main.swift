import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate: AppDelegate?
if CommandLine.arguments.contains("--acceptance-test") {
    appDelegate = nil
    Task { @MainActor in AcceptanceTestRunner.run() }
} else {
    appDelegate = AppDelegate()
    app.delegate = appDelegate
}
app.run()
