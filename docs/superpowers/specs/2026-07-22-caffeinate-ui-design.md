# caffeinate-ui — Design

**Date:** 2026-07-22
**Status:** Approved, pending implementation plan

## Purpose

A macOS menubar app that keeps the Mac awake, wrapping the system `caffeinate`
binary. Click the menubar icon, pick a duration, the Mac stays up. Click again
to release.

## Constraints

- **No Xcode.** The machine has Command Line Tools only (Swift 6.3.3). SwiftPM
  builds work; `.xcodeproj` and `xcodebuild` are unavailable. Everything here is
  buildable with `swift build`.
- **macOS 26.5**, Apple Silicon. Deployment target set to macOS 13.

## Approach

Spawn `/usr/bin/caffeinate` as a child process; terminate it to release. Not
IOKit power assertions — `caffeinate` is the platform feature that already wraps
those, and reaching past it would be writing code the OS ships.

### Crash safety

The child is spawned as:

```
/usr/bin/caffeinate <flags> -w <our-own-pid>
```

`-w` tells caffeinate to exit when the watched process exits. Passing our own
PID means that **if the app crashes or is force-quit, the child exits too**.
Without this, a crash leaves a `caffeinate` running with no UI to stop it,
pinning the Mac awake until the user finds it in Activity Monitor.

### Duration handling

Expiry is driven by the app's own `Timer`, not `caffeinate -t`. The timer
already exists to redraw the menubar countdown, so reusing it keeps one source
of truth for "when does this end". Using `-t` as well would mean two clocks that
can disagree, and the visible countdown could hit zero while the assertion is
still held (or the reverse).

## Structure

A single executable target. An earlier draft split logic into a `CaffeineKit`
library so SwiftPM could test it, but no test framework is available on this
machine (see Testing), so the split had no remaining justification.

```
Package.swift
Resources/Info.plist
scripts/bundle.sh
Sources/CaffeineApp/CaffeineController.swift   subprocess lifecycle, arg building
Sources/CaffeineApp/MenuController.swift       status item, menu, countdown timer
Sources/CaffeineApp/SelfCheck.swift            --self-check assertions
Sources/CaffeineApp/main.swift                 NSApp bootstrap and wiring
```

Target names must be valid Swift module identifiers, so the hyphenated name
lives on the *product*: `.executable(name: "caffeinate-ui", targets:
["CaffeineApp"])`. The built binary is `.build/release/caffeinate-ui`.

Only `main.swift` may contain top-level code; the other files hold declarations
only.

## Components

### `CaffeineController`

Owns the child process and the authoritative state.

```swift
enum State {
    case idle
    case active(until: Date?)   // nil = indefinite
}
```

API: `start(duration: TimeInterval?) throws`, `stop()`, `flags: Set<SleepFlag>`,
`onStateChange: (() -> Void)?`.

The process's `terminationHandler` resets state to `.idle`. A `caffeinate` that
dies on its own therefore cannot leave the UI claiming to be active.

Changing flags while active terminates and respawns with the new argv.

Two pure functions carry the logic worth testing:

- `caffeinateArgs(flags:watching:) throws -> [String]` — builds argv as flags in
  fixed `-d -i -m -s` order, then `-w <pid>`. The order is fixed rather than
  set-iteration order so the tests can assert on exact argv. Throws
  `CaffeineError.noFlagsSelected` on an empty set rather than spawning a
  `caffeinate` with no flags. Per `man caffeinate`, *"if no assertion flags are
  specified, caffeinate creates an assertion to prevent idle sleep"* — so an
  unflagged child would hold the Mac awake on an implicit idle assertion while
  the Prevent submenu showed every box unchecked. The UI would understate what
  is happening, not overstate it.
- `formatRemaining(_: TimeInterval) -> String` — `59s`, `42m`, `1h 05m`.

### `MenuController`

Owns the `NSStatusItem` and rebuilds the menu on state change. Runs a 1-second
`Timer` only while active with a finite duration; it updates the title and calls
`stop()` at expiry. Invalidated whenever state is idle or indefinite.

### `main.swift` (CaffeineApp)

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = CaffeineController()
let menu = MenuController(controller: controller)
app.run()
```

## Sleep flags

| Flag | Meaning                | Default |
|------|------------------------|---------|
| `-d` | Prevent display sleep  | on      |
| `-i` | Prevent idle sleep     | on      |
| `-m` | Prevent disk sleep     | off     |
| `-s` | Prevent system sleep   | off     |

`-d -i` is the default because it matches what "keep awake" means to most
people. `-s` only takes effect on AC power; the submenu item says so.

## Menu layout

```
☕ 42m              title: icon plus countdown, icon-only when idle
─────────────
  Indefinite         reads "Turn Off" while active
  15 minutes
  1 hour
  2 hours
─────────────
  Prevent ▸  ✓ Display (-d)
             ✓ Idle (-i)
               Disk (-m)
               System (-s, AC power only)
─────────────
  Quit
```

Icon: SF Symbol `cup.and.saucer.fill` when active, `cup.and.saucer` when idle,
as a template image so it inverts correctly in light and dark menubars.

## Launching

`swift run` works for iteration, but a menubar app you cannot double-click is
not finished. `scripts/bundle.sh` assembles a real `.app` — a directory layout,
not an Xcode project:

```
build/caffeinate-ui.app/
└── Contents/
    ├── Info.plist              LSUIElement=true, bundle id, version
    └── MacOS/caffeinate-ui     the release binary
```

The script runs `swift build -c release`, creates those paths, and copies the
binary and plist in. The result can be dragged to `/Applications` and launched
from Spotlight.

`LSUIElement=true` hides the dock icon for the bundled app. `setActivationPolicy(.accessory)`
stays in `main.swift` anyway so that a bare `swift run` also behaves as a
menubar app, without rebundling on every change.

Gatekeeper is not an obstacle: the binary is compiled locally and never receives
the `com.apple.quarantine` attribute, which is only applied to downloads.

## Error handling

`CaffeineController` owns the failure, as `lastError`, and `MenuController`
renders it. The error lives on the controller because not every spawn is
triggered by a UI action: changing flags mid-session respawns from the `flags`
observer, which has no call site to catch a throw. With one owner, every spawn
path — UI-driven or not — reports through the same channel instead of failing
silently.

- `Process.run()` throws → the menu shows a disabled `caffeinate unavailable`
  item instead of silently doing nothing.
- Child dies unexpectedly → `terminationHandler` returns state to `.idle`.
- Empty flag set → the spawn throws before any `Process` is built, and the menu
  shows `Select at least one Prevent option`. This is the case that would
  otherwise be silent: unchecking the last Prevent flag during a session ends
  it, and without a reported error the cup would simply empty with no
  explanation. See Components for why an unflagged `caffeinate` must not be
  spawned.

State and error changes funnel through one transition so observers are notified
exactly once per operation. Notifying only when `state` changes is not enough —
a failure raised while state is already `.idle` moves only `lastError`, and the
error would never reach the menu.

## Testing

**Neither `XCTest` nor `Testing` is importable with Command Line Tools only** —
both frameworks ship inside Xcode. This was verified on the machine, not
assumed; `swift test` cannot run here at all. The options were to add
swift-testing as a source dependency, install Xcode, or drop the framework.

The check therefore runs as a flag on the app itself:

```
swift run caffeinate-ui --self-check
```

`main.swift` intercepts the flag before `NSApp.run()`, executes the assertions
in `SelfCheck.swift`, prints a result, and exits — 0 on pass, non-zero on
failure, so it works in a git hook or CI later.

Assertions use `precondition`, not `assert`. `assert` is compiled out under
`-O`, which would make the self-check silently vacuous in the release build that
`bundle.sh` produces.

Coverage is the two pure functions plus the one controller path that reaches no
subprocess; a running child is never exercised.

- `caffeinateArgs` — flag sets produce correct argv including `-w <pid>`; empty
  set throws. Two design invariants are additionally checked across all 15
  non-empty flag subsets rather than a hand-picked case: argv always ends in
  `-w <pid>` (crash safety holds for every combination), and never contains
  `-t` (the deadline is `MenuController`'s `Timer` alone).
- `formatRemaining` — sub-minute, minutes, hours, the zero boundary, and a
  fractional input, which is what `MenuController` actually passes.
- `CaffeineController.start` with an empty flag set — must throw and leave the
  controller observably idle, pinning the invariant that `isActive` is never
  true unless a child is really running. Safe to assert here because the empty
  set throws inside `caffeinateArgs`, which `spawn` calls before it builds or
  runs a `Process`, so nothing is spawned and no power assertion is held.

Installing Xcode later would make a real test target viable; nothing in this
design blocks that.

## Out of scope for v1

- **Launch at login.** A LaunchAgent plist would do it without code signing, but
  it is not needed to validate the app.
- **Persisting flag choices** across restarts.
- **Sleep/wake event handling** — reacting to lid close, power source changes.
