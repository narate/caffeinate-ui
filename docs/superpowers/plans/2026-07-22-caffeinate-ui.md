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

    // An empty flag set must throw rather than spawn a caffeinate that holds
    // no assertion while the UI claims to be active.
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
  - `var onStateChange: (() -> Void)?`
  - `func start(duration: TimeInterval?) throws`, `func stop()`

There is no automated test for this task — it spawns a real subprocess, and no
test framework is available. Step 3 is a manual verification against `pgrep`.

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

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?() } }
    }

    /// Display and idle sleep — what "keep awake" means to most people.
    var flags: Set<SleepFlag> = [.display, .idle] {
        didSet {
            guard flags != oldValue else { return }
            if case .active(let until) = state { restart(until: until) }
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
            state = .active(until: until)
        } catch {
            state = .idle
            throw error
        }
    }

    func stop() {
        killChild()
        state = .idle
    }

    /// Flags changed mid-session: swap the child without disturbing the deadline.
    private func restart(until: Date?) {
        killChild()
        do {
            try spawn()
            state = .active(until: until)
        } catch {
            state = .idle
        }
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
                self.state = .idle
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
- Consumes: `CaffeineController`, `CaffeineController.State`, `SleepFlag`, `CaffeineError`, `formatRemaining(_:)`
- Produces: `final class MenuController: NSObject`, `init(controller:)`, `func install()`

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
    private var lastError: Error?

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
        let symbol = controller.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "caffeinate")
        image?.isTemplate = true   // inverts correctly in light and dark menubars
        statusItem.button?.image = image

        if case .active(let until) = controller.state, let until {
            statusItem.button?.title = " " + formatRemaining(until.timeIntervalSinceNow)
        } else {
            statusItem.button?.title = ""
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let lastError {
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
            // Row 0 doubles as the off switch once something is running.
            let isOffRow = duration.seconds == nil && controller.isActive
            let item = NSMenuItem(title: isOffRow ? "Turn Off" : duration.title,
                                  action: #selector(selectDuration(_:)),
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

    @objc private func selectDuration(_ sender: NSMenuItem) {
        let duration = Self.durations[sender.tag]
        if duration.seconds == nil && controller.isActive {
            controller.stop()
            return
        }
        do {
            lastError = nil
            try controller.start(duration: duration.seconds)
        } catch {
            lastError = error
            refresh()
        }
    }

    @objc private func toggleFlag(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let flag = SleepFlag(rawValue: raw) else { return }
        var updated = controller.flags
        if updated.contains(flag) { updated.remove(flag) } else { updated.insert(flag) }
        controller.flags = updated
        refresh()
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
8. `Quit` exits, and `pgrep -fl caffeinate` afterward shows no leftover child.

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
| Error → disabled menu item | 4 |
| `--self-check` with `precondition` | 1, 2 |
| `bundle.sh`, `Info.plist`, `LSUIElement` | 5 |
| Gatekeeper non-issue | 5 (verified in step 4) |

No gaps.

**Placeholder scan:** No TBD/TODO. Every code step carries complete code. The
one step that removes code (Task 3 Step 4) names exactly what to delete.

**Type consistency:** `caffeinateArgs(flags:watching:)`, `formatRemaining(_:)`,
`start(duration:)`, `stop()`, `onStateChange`, `isActive`, `state`, `flags`,
and `install()` are spelled identically in the interface blocks and every
call site. `State.active(until:)` is destructured as `case .active(let until)`
throughout.

**Note on Task 3:** it is the only task without an automated check, because it
spawns a real subprocess and no test framework exists here. Its manual `pgrep`
verification is the compensating control and should not be skipped — it is the
only thing that proves the crash-safety design works.
