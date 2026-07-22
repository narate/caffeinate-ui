import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService` (macOS 13+).
///
/// `SMAppService.mainApp` identifies the app by its bundle, so this only means
/// anything for the bundled `.app` that `scripts/bundle.sh` produces — a bare
/// `swift run` binary has no bundle identifier and nothing to register.
/// `isAvailable` reports that case so the menu can omit the item rather than
/// offer a toggle that silently does nothing.
///
/// `isEnabled` reads the live system status rather than caching a flag: the user
/// can revoke login items from System Settings, and a cached value would leave
/// the checkmark asserting something the system no longer agrees with.
enum LoginItem {

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
