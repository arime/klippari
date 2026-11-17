import AppKit

let app = NSApplication.shared
Snapshot.runIfRequested()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
