import AppKit

/// Renders a remaining duration for the menubar title: "59s", "42m", "1h 05m".
/// Negative intervals clamp to "0s".
func formatRemaining(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}

/// Upper bound on a custom duration, in seconds (7 days).
///
/// Bounded because the value becomes a live deadline: an unbounded field turns
/// a fat-fingered paste into a session that outlives the user's interest in it,
/// with no way to tell from the menubar that anything is wrong. Seven days
/// rather than one so that the `d` suffix is worth having — a 24-hour cap would
/// accept `1d` and reject every other value of it.
let maxCustomSeconds: TimeInterval = 7 * 24 * 3600

/// Parses a custom-duration entry into a `TimeInterval`, or `nil` if it is not a
/// whole number of `s`/`m`/`h`/`d` within `1...maxCustomSeconds`.
///
/// A bare number means minutes, which is both the most common case and what the
/// field accepted before suffixes existed.
///
/// Whitespace is stripped everywhere rather than only at the ends, so `2 h`
/// works. Decimals are still rejected: `1.5h` would have to round somewhere the
/// user cannot see, and `90m` says the same thing without the ambiguity.
func parseDuration(_ text: String) -> TimeInterval? {
    let cleaned = text.filter { !$0.isWhitespace }.lowercased()
    guard !cleaned.isEmpty else { return nil }

    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]

    let magnitude: String
    let unit: TimeInterval
    if let suffix = cleaned.last, let multiplier = units[suffix] {
        magnitude = String(cleaned.dropLast())
        unit = multiplier
    } else {
        magnitude = cleaned
        unit = 60
    }

    // `Int` rejects decimals, exponents, and values too large to represent, so
    // the range check below only has to police intent, not arithmetic.
    guard let value = Int(magnitude) else { return nil }

    let seconds = TimeInterval(value) * unit
    guard seconds >= 1, seconds <= maxCustomSeconds else { return nil }
    return seconds
}

extension SleepFlag {
    var menuTitle: String {
        switch self {
        case .display: return "Display (-d)"
        case .idle:    return "Idle (-i)"
        case .disk:    return "Disk (-m)"
        case .system:  return "System (-s, AC power only)"
        }
    }
}

/// Owns the status item and renders CaffeineController's state.
final class MenuController: NSObject {

    private let controller: CaffeineController
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    /// Surfaced in the menu when a login-item toggle throws. Kept separate from
    /// the controller's `lastError`, which is about holding the Mac awake — the
    /// two failures are unrelated and must not overwrite each other.
    private var loginItemError: String?

    /// `nil` seconds means indefinite. Index into this array is the menu tag.
    private static let durations: [(title: String, seconds: TimeInterval?)] = [
        ("Indefinite", nil),
        ("15 minutes", 15 * 60),
        ("1 hour",     60 * 60),
        ("2 hours",     2 * 60 * 60),
    ]

    init(controller: CaffeineController) {
        self.controller = controller
        super.init()
        controller.onStateChange = { [weak self] in self?.refresh() }
    }

    func install() { refresh() }

    private func refresh() {
        updateTitle()
        rebuildMenu()
        updateTimer()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        // Explicit, so icon-plus-countdown layout does not depend on whatever
        // AppKit's inherited default happens to be.
        button.imagePosition = .imageLeading

        let symbol = controller.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "caffeinate")
        image?.isTemplate = true   // inverts correctly in light and dark menubars

        let countdown: String
        if case .active(let until) = controller.state, let until {
            countdown = " " + formatRemaining(until.timeIntervalSinceNow)
        } else {
            countdown = ""
        }

        if let image {
            button.image = image
            button.title = countdown
        } else {
            // The symbol lookup is optional, and assigning nil would leave a
            // zero-width, unclickable status item — no icon, no title, and no
            // way to reach Quit from inside the app. Fall back to text so the
            // menu stays reachable.
            button.image = nil
            button.title = "☕" + countdown
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let lastError = controller.lastError {
            // Report the actual failure. An empty flag set and a missing
            // binary are different problems and must not share a message.
            let message = (lastError as? CaffeineError) == .noFlagsSelected
                ? "Select at least one Prevent option"
                : "caffeinate unavailable"
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        for (index, duration) in Self.durations.enumerated() {
            // Row 0 doubles as the off switch once something is running. Bind
            // the action to the label decided here, never re-derive intent from
            // `controller.isActive` at click time: AppKit keeps displaying a
            // menu it is already tracking even after `statusItem.menu` is
            // reassigned, so a row reading "Turn Off" can be clicked after the
            // session has already ended (deadline expiry with the menu open, or
            // the child killed externally). Re-deriving would then read
            // `isActive == false` and start an indefinite session — the exact
            // opposite of what the row says.
            let isOffRow = duration.seconds == nil && controller.isActive
            let item = NSMenuItem(title: isOffRow ? "Turn Off" : duration.title,
                                  action: isOffRow ? #selector(stopSession)
                                                   : #selector(selectDuration(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }

        let custom = NSMenuItem(title: "Custom…",
                                action: #selector(selectCustomDuration),
                                keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)

        menu.addItem(.separator())

        let prevent = NSMenuItem(title: "Prevent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for flag in SleepFlag.allCases {
            let item = NSMenuItem(title: flag.menuTitle,
                                  action: #selector(toggleFlag(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = flag.rawValue
            item.state = controller.flags.contains(flag) ? .on : .off
            submenu.addItem(item)
        }
        prevent.submenu = submenu
        menu.addItem(prevent)

        menu.addItem(.separator())

        // Omitted entirely when unbundled: SMAppService has no bundle to
        // register, so the toggle would be a lie rather than a feature.
        if LoginItem.isAvailable {
            let launch = NSMenuItem(title: "Launch at Login",
                                    action: #selector(toggleLoginItem),
                                    keyEquivalent: "")
            launch.target = self
            launch.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(launch)

            if let loginItemError {
                let item = NSMenuItem(title: "Login item failed: \(loginItemError)",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// Recreated on every refresh; only runs while a finite deadline is set.
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard case .active(let until) = controller.state, let until else { return }

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if until.timeIntervalSinceNow <= 0 {
                self.controller.stop()
            } else {
                self.updateTitle()
            }
        }
        // .common, not the default mode, so the countdown keeps ticking while
        // the menu is open and the runloop is in event-tracking mode.
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    /// The off row's own action. A stale "Turn Off" click therefore stops — or
    /// harmlessly does nothing if the session already ended — instead of
    /// starting an indefinite one.
    @objc private func stopSession() { controller.stop() }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        do {
            try controller.start(duration: Self.durations[sender.tag].seconds)
        } catch {
            // The controller has already recorded this in `lastError` and fired
            // onStateChange, which rebuilt this menu with the error row. There
            // is nothing left to do here, and refreshing again would depend on
            // an ordering that is easy to get wrong.
        }
    }

    @objc private func selectCustomDuration() {
        // An .accessory app is not the active app, so without this the panel
        // opens behind whatever the user is actually looking at.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Keep awake for how long?"
        alert.informativeText =
            "30s, 45m, 2h, 1d — a bare number means minutes. Up to 7 days."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "45m"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let duration = parseDuration(field.stringValue) else {
            // Reported here rather than as a menu row: the menu has already
            // closed by now, so a row would not be seen until the user next
            // opened it — long after the typo stopped making sense.
            let invalid = NSAlert()
            invalid.alertStyle = .warning
            invalid.messageText = "Not a valid duration"
            invalid.informativeText =
                "Try 30s, 45m, 2h, or 1d. A bare number means minutes. "
                + "Whole numbers only, up to 7 days."
            invalid.runModal()
            return
        }

        do {
            try controller.start(duration: duration)
        } catch {
            // Already recorded in the controller's lastError, which rebuilt the
            // menu with the error row — same contract as selectDuration.
        }
    }

    @objc private func toggleLoginItem() {
        do {
            loginItemError = nil
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            loginItemError = error.localizedDescription
        }
        // Not a controller state change, so nothing else will redraw this.
        refresh()
    }

    @objc private func toggleFlag(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let flag = SleepFlag(rawValue: raw) else { return }
        var updated = controller.flags
        if updated.contains(flag) { updated.remove(flag) } else { updated.insert(flag) }
        // No refresh here: `flags`'s observer notifies on both branches — after
        // respawning when active, and directly when idle — so the redraw
        // happens exactly once either way.
        controller.flags = updated
    }
}
