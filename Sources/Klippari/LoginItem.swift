import Foundation
import ServiceManagement
import os

/// Start-at-login via the system login item service.
@MainActor enum LoginItem {
    private static let registeredKey = "didRegisterLoginItem"
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "login")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Start at login is on by default: register once per install. Only
    /// from /Applications, because the login item is tied to the bundle's
    /// path and a build-folder copy would leave a stale entry behind.
    static func registerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !defaults.bool(forKey: registeredKey)
        else { return }
        do {
            try setEnabled(true)
            // Only remember success, so a failure is retried next launch.
            defaults.set(true, forKey: registeredKey)
        } catch {
            logger.error("Could not register login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
