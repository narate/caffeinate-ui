# caffeinate-ui Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menubar app that keeps the Mac awake by wrapping the system `caffeinate` binary, with duration presets, a live countdown, and per-sleep-type flags.

**Architecture:** A single SwiftPM executable target. `CaffeineController` owns a child `caffeinate` process and the authoritative state; `MenuController` owns the `NSStatusItem` and renders that state. The child is spawned watching our own PID (`-w $$`) so it dies with us. `scripts/bundle.sh` assembles a real `.app` from the release binary.

**Tech Stack:** Swift 6.3.3, SwiftPM, AppKit (`NSStatusItem`, `NSMenu`), Foundation `Process`. No third-party dependencies.

## Global Constraints

- **No Xcode on this machine** — Command Line Tools only. `xcodebuild` and `.xcodeproj` are unavailable. Every command in this plan is `swift build` / `swift run` / plain shell.
- **No test framework exists here.** Both `import XCTest` and `import Testing` fail with `no such module` — both ship inside Xcode. This was verified, not assumed. All checks run via `swift run caffeinate-ui --self-check`.
- **Use `precondition`, never `assert`,** in self-check code. `assert` is compiled out under `-O`, which would make the self-check silently vacuous in the release build `bundle.sh` produces.
- **Deployment target:** macOS 13. swift-tools-version 5.9.
- **Target name is `CaffeineApp`; product name is `caffeinate-ui`.** Target names must be valid Swift module identifiers, so the hyphen can only live on the product.
- **Only `main.swift` may contain top-level code.** Every other file holds declarations only — this is a SwiftPM executable-target rule, and violating it is a compile error.
- Flag argv order is always `-d -i -m -s`, then `-w <pid>`.

---

### Task 1: Package skeleton, `caffeinateArgs`, and the self-check harness

**Files:**
- Create: `Package.swift`
- Create: `Sources/CaffeineApp/CaffeineController.swift`
- Create: `Sources/CaffeineApp/SelfCheck.swift`
- Create: `Sources/CaffeineApp/main.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces:
  - `enum SleepFlag: String, CaseIterable` with cases `.display "-d"`, `.idle "-i"`, `.disk "-m"`, `.system "-s"`
  - `enum CaffeineError: Error, Equatable { case noFlagsSelected }`
  - `func caffeinateArgs(flags: Set<SleepFlag>, watching pid: pid_t) throws -> [String]`
  - `func runSelfCheck()`

- [ ] **Step 1: Create the package manifest**

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "caffeinate-ui",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "caffeinate-ui", targets: ["CaffeineApp"])
    ],
    targets: [
        .executableTarget(name: "CaffeineApp")
    ]
)
```

- [ ] **Step 2: Write the failing self-check**

`Sources/CaffeineApp/SelfCheck.swift`:

```swift
import Foundation

/// Runs every assertion in the project. Invoked by `--self-check`.
/// Uses `precondition` rather than `assert` so the checks survive `-O`.
func runSelfCheck() {
    // Flags emit in fixed -d -i -m -s order regardless of insertion order.
    precondition(try! caffeinateArgs(flags: [.idle, .display], watching: 42)
                 == ["-d", "-i", "-w", "42"])
    precondition(try! caffeinateArgs(flags: [.system, .disk], watching: 7)
                 == ["-m", "-s", "-w", "7"])
    precondition(try! caffeinateArgs(flags: Set(SleepFlag.allCases), watching: 1)
                 == ["-d", "-i", "-m", "-s", "-w", "1"])

    // An empty flag set must throw rather than spawn a bare `caffeinate`.
    // Per `man caffeinate`: "If no assertion flags are specified, caffeinate
    // creates an assertion to prevent idle sleep." So an unflagged child holds
    // the Mac awake on an implicit idle assertion while the Prevent submenu
    // shows every box unchecked — the UI would understate what is happening,
    // not overstate it.
    do {
        _ = try caffeinateArgs(flags: [], watching: 1)
        preconditionFailure("empty flag set should have thrown")
    } catch let error as CaffeineError {
        precondition(error == .noFlagsSelected)
    } catch {
        preconditionFailure("unexpected error: \(error)")
    }

    print("self-check ok")
}
```

`Sources/CaffeineApp/main.swift`:

```swift
import AppKit

if CommandLine.arguments.contains("--self-check") {
    runSelfCheck()
    exit(0)
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift run caffeinate-ui --self-check`
Expected: FAIL — `error: cannot find 'caffeinateArgs' in scope` (and the same for `SleepFlag` / `CaffeineError`).

- [ ] **Step 4: Write the minimal implementation**

`Sources/CaffeineApp/CaffeineController.swift`:

```swift
import Foundation

enum SleepFlag: String, CaseIterable {
    case display = "-d"
    case idle    = "-i"
    case disk    = "-m"
    case system  = "-s"
}

enum CaffeineError: Error, Equatable {
    case noFlagsSelected
}

/// Builds argv for `/usr/bin/caffeinate`.
///
/// Flags emit in `allCases` order (`-d -i -m -s`) rather than set-iteration
/// order, which is unstable, so the output is assertable.
///
/// `pid` is our own process id: `-w` makes caffeinate exit when that process
/// exits, so a crash cannot strand a child holding the Mac awake.
func caffeinateArgs(flags: Set<SleepFlag>, watching pid: pid_t) throws -> [String] {
    guard !flags.isEmpty else { throw CaffeineError.noFlagsSelected }
    return SleepFlag.allCases.filter(flags.contains).map(\.rawValue)
         + ["-w", String(pid)]
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `swift run caffeinate-ui --self-check`
Expected: PASS — prints `self-check ok`, exit code 0.

Confirm the exit code: `swift run caffeinate-ui --self-check; echo $status`
Expected: `0` (this is fish; in bash it is `$?`).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CaffeineApp/
git commit -m "Add package skeleton, caffeinateArgs, and self-check harness"
```

---

### Task 2: `formatRemaining`

**Files:**
- Create: `Sources/CaffeineApp/MenuController.swift`
- Modify: `Sources/CaffeineApp/SelfCheck.swift`

**Interfaces:**
- Consumes: `runSelfCheck()` from Task 1
- Produces: `func formatRemaining(_ interval: TimeInterval) -> String`

- [ ] **Step 1: Write the failing assertions**

Add to `runSelfCheck()` in `Sources/CaffeineApp/SelfCheck.swift`, immediately before the `print("self-check ok")` line:

```swift
    // formatRemaining: seconds under a minute, whole minutes under an hour,
    // then "1h 05m". Negative intervals clamp to "0s" so an overdue timer
    // never renders "-3s".
    precondition(formatRemaining(0)    == "0s")
    precondition(formatRemaining(-5)   == "0s")
    precondition(formatRemaining(59)   == "59s")
    // Fractional input, which is what MenuController actually passes
    // (`until.timeIntervalSinceNow`). The only place round-vs-truncate is
    // user-visible: a fresh 15m session reads 899.9995s — "15m" rounded,
    // "14m" truncated.
    precondition(formatRemaining(59.6) == "1m")
    precondition(formatRemaining(60)   == "1m")
    precondition(formatRemaining(3599) == "59m")
    precondition(formatRemaining(3600) == "1h 00m")
    precondition(formatRemaining(3900) == "1h 05m")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift run caffeinate-ui --self-check`
Expected: FAIL — `error: cannot find 'formatRemaining' in scope`.

- [ ] **Step 3: Write the minimal implementation**

`Sources/CaffeineApp/MenuController.swift`:

```swift
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift run caffeinate-ui --self-check`
Expected: PASS — prints `self-check ok`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaffeineApp/
git commit -m "Add formatRemaining for the menubar countdown"
```

---

### Task 3: `CaffeineController` process lifecycle

**Files:**
- Modify: `Sources/CaffeineApp/CaffeineController.swift`

**Interfaces:**
- Consumes: `caffeinateArgs(flags:watching:)`, `SleepFlag`, `CaffeineError` from Task 1
- Produces:
  - `final class CaffeineController`
  - `CaffeineController.State` — `.idle` / `.active(until: Date?)`, `Equatable`
  - `var state: State { get }`, `var flags: Set<SleepFlag>`, `var isActive: Bool`
  - `var lastError: Error? { get }`
  - `var onStateChange: (() -> Void)?`
  - `func start(duration: TimeInterval?) throws`, `func stop()`

The subprocess itself has no automated test — it spawns for real, and no test
framework is available. Step 3 is a manual verification against `pgrep`. The one
path that reaches no subprocess *is* asserted in Task 6: a start with an empty
flag set must throw and leave the controller idle.

`lastError` lives on the controller rather than on `MenuController` because not
every spawn is triggered by a UI action. Changing flags mid-session respawns
from the `flags` observer, which has no call site to catch a throw — so a
failure there (dropping the last Prevent flag, or a genuine `Process.run()`
error) would otherwise vanish silently, emptying the cup with no explanation.
One owner means every spawn path reports through the same channel.

- [ ] **Step 1: Implement the controller**

Append to `Sources/CaffeineApp/CaffeineController.swift`:

```swift
/// Owns the child `caffeinate` process and the authoritative awake state.
final class CaffeineController {

    enum State: Equatable {
        case idle
        /// `until == nil` means indefinite.
        case active(until: Date?)
    }

    private(set) var state: State = .idle

    /// The last spawn failure, or `nil` if the last spawn attempt succeeded.
    ///
    /// Owned here rather than in the UI because not every spawn is triggered by
    /// a UI action: unchecking the last Prevent flag mid-session respawns from
    /// `flags`'s observer, and that path has no call site to catch a throw. With
    /// the error living here, every spawn — UI-driven or not — reports through
    /// one channel.
    private(set) var lastError: Error?

    /// Display and idle sleep — what "keep awake" means to most people.
    var flags: Set<SleepFlag> = [.display, .idle] {
        didSet {
            guard flags != oldValue else { return }
            if case .active(let until) = state {
                restart(until: until)
            } else {
                // Idle: nothing to respawn, but observers still need to redraw
                // the checkmarks — and a "no flags selected" complaint is now
                // stale, since the user just changed the setting it was about.
                lastError = nil
                onStateChange?()
            }
        }
    }

    var onStateChange: (() -> Void)?

    private var process: Process?

    var isActive: Bool { state != .idle }

    func start(duration: TimeInterval?) throws {
        killChild()
        let until = duration.map { Date().addingTimeInterval($0) }
        do {
            try spawn()
            transition(to: .active(until: until))
        } catch {
            transition(to: .idle, error: error)
            throw error
        }
    }

    func stop() {
        killChild()
        transition(to: .idle)
    }

    /// Flags changed mid-session: swap the child without disturbing the deadline.
    ///
    /// The failure here is the one with no other way out: dropping the last
    /// Prevent flag makes `spawn` throw, and silently falling back to `.idle`
    /// would empty the cup and clear the countdown with nothing saying why.
    private func restart(until: Date?) {
        killChild()
        do {
            try spawn()
            transition(to: .active(until: until))
        } catch {
            transition(to: .idle, error: error)
        }
    }

    /// The single funnel for state and error changes, so observers get exactly
    /// one notification per operation and never see a half-updated view where
    /// `state` has moved but `lastError` has not.
    ///
    /// Notifying on `state` changes alone is not enough: a failure raised while
    /// state is already `.idle` moves only `lastError`, and the error would
    /// never reach the menu. Only a true no-op — same state, no error before or
    /// after — skips the notification, because a redundant redraw is harmless
    /// while a missed one leaves the UI lying.
    private func transition(to newState: State, error: Error? = nil) {
        let isNoOp = newState == state && error == nil && lastError == nil
        state = newState
        lastError = error
        if !isNoOp { onStateChange?() }
    }

    /// Clears the termination handler before terminating, so our own kill does
    /// not re-enter the handler and clobber a state transition in progress.
    private func killChild() {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    private func spawn() throws {
        let args = try caffeinateArgs(flags: flags, watching: getpid())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        child.arguments = args
        // If caffeinate dies on its own, fall back to idle so the UI cannot
        // keep claiming the Mac is being held awake. Guard on identity, not
        // nil-ness: this handler belongs to `child`, and by the time it runs
        // on main, `self.process` may already be a newer child that replaced
        // it. Only clear state if `child` is still the current process.
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.process = nil
                // Not an error we raised — the child simply ended. `lastError`
                // is already nil here, since a running child means the spawn
                // that produced it succeeded and cleared it.
                self.transition(to: .idle)
            }
        }
        try child.run()
        self.process = child
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Manually verify the child spawns and dies with the parent**

This proves the `-w $$` crash-safety design actually works. Add a temporary
block to `Sources/CaffeineApp/main.swift`, directly below the `--self-check`
block:

```swift
if CommandLine.arguments.contains("--spawn-probe") {
    let probe = CaffeineController()
    try! probe.start(duration: nil)
    print("spawned, pid \(getpid()) — inspect with pgrep, exiting in 3s")
    Thread.sleep(forTimeInterval: 3)
    exit(0)
}
```

Run it in the background and watch the child:

```bash
swift run caffeinate-ui --spawn-probe &
sleep 1
pgrep -fl caffeinate | grep -- -w
sleep 4
pgrep -fl caffeinate | grep -- -w || echo "child exited with parent — correct"
```

Expected: the first `pgrep` prints a `/usr/bin/caffeinate -d -i -w <pid>` line;
after the parent exits, the second prints `child exited with parent — correct`.

If the child survives, `-w` is not wired up — check that `getpid()` is being
passed and not a hardcoded value.

- [ ] **Step 4: Remove the probe**

Delete the `--spawn-probe` block from `main.swift`. It was scaffolding for a
one-time manual check, not a feature.

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/CaffeineApp/
git commit -m "Add CaffeineController subprocess lifecycle"
```

---

### Task 4: `MenuController` and app wiring

**Files:**
- Modify: `Sources/CaffeineApp/MenuController.swift`
- Modify: `Sources/CaffeineApp/main.swift`

**Interfaces:**
- Consumes: `CaffeineController`, `CaffeineController.State`, `CaffeineController.lastError`, `SleepFlag`, `CaffeineError`, `formatRemaining(_:)`
- Produces: `final class MenuController: NSObject`, `init(controller:)`, `func install()`

`MenuController` renders errors but does not own them — it reads
`controller.lastError`. It also never re-derives a row's intent at click time:
the off row carries its own `stopSession` action, decided when the row's label
was. AppKit keeps displaying a menu it is already tracking even after
`statusItem.menu` is reassigned, so a row reading "Turn Off" can outlive the
session it refers to; a handler that consulted `controller.isActive` at that
moment would start an indefinite session instead of stopping one.

- [ ] **Step 1: Implement the menu**

Append to `Sources/CaffeineApp/MenuController.swift`:

```swift
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
```

- [ ] **Step 2: Wire up the app**

`Sources/CaffeineApp/main.swift` in full:

```swift
import AppKit

if CommandLine.arguments.contains("--self-check") {
    runSelfCheck()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, menubar only

let controller = CaffeineController()
let menuController = MenuController(controller: controller)
menuController.install()

app.run()
```

`menuController` is a top-level `let`, which retains it for the life of the
process. A local binding would be deallocated and the menu would go dead.

- [ ] **Step 3: Verify the self-check still passes**

Run: `swift run caffeinate-ui --self-check`
Expected: PASS — prints `self-check ok`.

- [ ] **Step 4: Run the app and verify it by hand**

Run: `swift run caffeinate-ui`

Check each of these:
1. A coffee-cup icon appears in the menubar, with no dock icon.
2. Click it — the menu shows `Indefinite`, `15 minutes`, `1 hour`, `2 hours`, a `Prevent` submenu, and `Quit`.
3. Choose `15 minutes` — the icon fills in and the title shows a countdown that decrements each second.
4. `Prevent` shows Display and Idle checked, Disk and System unchecked.
5. Re-open the menu — row 0 now reads `Turn Off`. Click it; the countdown clears and the icon empties.
6. In another terminal while active: `pgrep -fl caffeinate` shows the child with the expected flags.
7. Uncheck every `Prevent` option, then pick a duration — the menu shows `Select at least one Prevent option` rather than pretending to work.
8. Re-check a `Prevent` option — that message clears, since the setting it complained about has changed.
9. Start a session, then uncheck `Prevent` options until none are left. The session ends *and* the menu shows `Select at least one Prevent option`. The failure here happens inside the `flags` observer with no UI call site to catch it, so a silent fallback to idle would empty the cup with nothing saying why.
10. Start a 15-minute session, open the menu, and leave it open past a manually shortened deadline (or run `killall caffeinate` in another terminal). The still-displayed row reads `Turn Off`; clicking it must not start an indefinite session.
11. `Quit` exits, and `pgrep -fl caffeinate` afterward shows no leftover child.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaffeineApp/
git commit -m "Add menubar UI and wire up the app"
```

---

### Task 5: `.app` bundle

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/bundle.sh`

**Interfaces:**
- Consumes: the `caffeinate-ui` release binary and the `--self-check` flag
- Produces: `build/caffeinate-ui.app`

- [ ] **Step 1: Write the bundle property list**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>caffeinate-ui</string>
    <key>CFBundleIdentifier</key>          <string>dev.narate.caffeinate-ui</string>
    <key>CFBundleName</key>                <string>caffeinate-ui</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>0.1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
</dict>
</plist>
```

`LSUIElement` is what hides the dock icon for the bundled app.

- [ ] **Step 2: Write the bundle script**

`scripts/bundle.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

# Run the self-check against the release binary specifically. This is the only
# thing proving the preconditions survived -O and were not optimized away.
.build/release/caffeinate-ui --self-check

APP="build/caffeinate-ui.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/caffeinate-ui "$APP/Contents/MacOS/caffeinate-ui"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "built $APP"
```

- [ ] **Step 3: Make it executable and run it**

```bash
chmod +x scripts/bundle.sh
./scripts/bundle.sh
```

Expected: prints `self-check ok`, then `built build/caffeinate-ui.app`.

If `self-check ok` does not appear, the preconditions were stripped — confirm
the code uses `precondition` and not `assert`.

- [ ] **Step 4: Verify the bundle launches**

```bash
open build/caffeinate-ui.app
```

Expected: the menubar icon appears with no dock icon and no Gatekeeper prompt
(a locally compiled binary never receives the `com.apple.quarantine` attribute).

Verify the bundled process is the one running: `pgrep -fl caffeinate-ui`
Expected: a path inside `caffeinate-ui.app/Contents/MacOS/`.

Quit it from the menubar before moving on.

- [ ] **Step 5: Commit**

```bash
git add Resources/Info.plist scripts/bundle.sh
git commit -m "Add .app bundle script and Info.plist"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Spawn `caffeinate` as child, terminate to release | 3 |
| `-w <own pid>` crash safety | 1 (argv), 3 (verified) |
| Duration via own Timer, not `-t` | 4 |
| Single executable target, `CaffeineApp` / `caffeinate-ui` | 1 |
| `State` enum, `terminationHandler` resets to idle | 3 |
| Flags change while active → respawn | 3 |
| `caffeinateArgs` fixed order, throws on empty | 1 |
| `formatRemaining` | 2 |
| Menu layout, `Turn Off` label, Prevent submenu | 4 |
| Defaults `-d -i`, `-s` labelled AC-only | 3 (default), 4 (label) |
| SF Symbol template icon | 4 |
| 1-second timer, only while finite | 4 |
| `setActivationPolicy(.accessory)` | 4 |
| Error → disabled menu item | 3 (`lastError` owner), 4 (renders it) |
| `--self-check` with `precondition` | 1, 2 |
| `bundle.sh`, `Info.plist`, `LSUIElement` | 5 |
| Gatekeeper non-issue | 5 (verified in step 4) |

No gaps.

**Placeholder scan:** No TBD/TODO. Every code step carries complete code. The
one step that removes code (Task 3 Step 4) names exactly what to delete.

**Type consistency:** `caffeinateArgs(flags:watching:)`, `formatRemaining(_:)`,
`start(duration:)`, `stop()`, `onStateChange`, `isActive`, `state`, `flags`,
`lastError`, and `install()` are spelled identically in the interface blocks and
every call site. `State.active(until:)` is destructured as
`case .active(let until)` throughout.

**Note on Task 3:** its *running subprocess* is the one thing no automated check
covers, because it spawns for real and no test framework exists here. The manual
`pgrep` verification is the compensating control and should not be skipped — it
is the only thing that proves the crash-safety design works. The controller's
rejected-start path *is* asserted, since it throws before any `Process` is built
and so has no side effect to worry about.
