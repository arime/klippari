import AppKit

// Everything the app writes is for this user only: history files are
// created 0600 and folders 0700 even where a write does not say so.
umask(0o077)

let app = NSApplication.shared
Snapshot.runIfRequested()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
