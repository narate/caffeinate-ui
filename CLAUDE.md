# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A macOS menubar app that keeps the Mac awake by wrapping the system `caffeinate` binary.

## Commands

```bash
swift build                          # debug build
swift run caffeinate-ui              # run as menubar app (no bundle needed)
swift run caffeinate-ui --self-check # run all assertions — this is the test suite
./scripts/bundle.sh                  # release build + self-check + build/caffeinate-ui.app
open build/caffeinate-ui.app         # launch the bundled app
```

## Environment constraint that shapes everything

**This machine has Command Line Tools, not Xcode.** `xcodebuild` and `.xcodeproj` are unavailable, and — critically — **there is no test framework**: both `import XCTest` and `import Testing` fail with `no such module`, because both ship inside Xcode. `swift test` cannot work here.

So `--self-check` in `SelfCheck.swift` is the entire automated safety net. Consequences:

- **Use `precondition`, never `assert`.** `assert` is compiled out under `-O`, which would make the self-check silently vacuous in the release binary. `scripts/bundle.sh` runs the self-check against the *release* binary specifically to prove the checks survived optimization — if `self-check ok` stops printing during a bundle run, the checks were stripped.
- There is no test target, and adding one will not work. Add assertions to `runSelfCheck()` instead.
- If Xcode is ever installed, a real test target becomes viable and nothing in the design blocks it.

## Architecture

Single SwiftPM executable target. Target is `CaffeineApp`, product is `caffeinate-ui` — target names must be valid Swift module identifiers, so the hyphen can only live on the product.

**Only `main.swift` may contain top-level code.** Every other file holds declarations only; violating this is a compile error.

- `CaffeineController.swift` — argv construction plus the child-process lifecycle and the authoritative state machine
- `MenuController.swift` — `formatRemaining` plus the `NSStatusItem`, menu, and countdown timer
- `LoginItem.swift` — launch-at-login via `SMAppService`
- `SelfCheck.swift` — every assertion in the project
- `main.swift` — intercepts `--self-check`, then bootstraps `NSApp`

### Design invariants — do not break these

**Crash safety: the child is spawned as `caffeinate <flags> -w <our own pid>`.** `-w` makes `caffeinate` exit when the watched process exits, so an app crash cannot strand a child holding the Mac awake with no UI to stop it. This is the core safety property of the whole design.

**The deadline belongs to `MenuController`'s `Timer`, never to `caffeinate -t`.** One source of truth. A `-t` anywhere is a defect, and the self-check asserts its absence across all flag subsets.

**The termination handler's closure captures `child` strongly, on purpose.** That strong capture is what rules out ABA pointer aliasing and makes the `self.process === child` identity guard sound. It looks like a retain cycle worth "cleaning up" — it is not. Weakening it reintroduces a bug where a dead child's late callback orphans a live one, leaving a `caffeinate` running that the UI cannot stop.

**All state changes route through `CaffeineController.transition(to:error:force:)`.** It suppresses no-op transitions to avoid spurious menu rebuilds. `force: true` exists for one case: a flag change respawns the child with the same deadline, so `state` is unmoved but the menu still needs redrawing. Callers do not call `refresh()` themselves — the controller notifies.

**`lastError` lives on the controller, not the menu.** Every spawn path reports failure through that one channel, so a failure during a flag change surfaces the same way as one during an explicit start.

### Bundle-only features

Launch-at-login and the icon exist only in the bundled `.app`, not under `swift run`:

- `SMAppService` identifies the login item by **code signature**, so `bundle.sh` ad-hoc signs (`codesign --sign -`) — an unsigned bundle is rejected on registration. Ad-hoc is all CLT can produce and it is sufficient; this was verified by registering and unregistering a real bundle, not assumed.
- `LoginItem.isAvailable` is false when `Bundle.main.bundleIdentifier` is nil, and the menu **omits** the item entirely rather than showing a toggle that cannot work.
- `LoginItem.isEnabled` reads live `SMAppService` status every time. Do not cache it — the user can revoke login items in System Settings, and a cached flag would leave the checkmark asserting something the system disagrees with.

**The app icon may not use an SF Symbol.** Apple's SF Symbols license prohibits symbols in app icons, so `scripts/make-icon.swift` draws the cup from Core Graphics paths. It is generated at bundle time, not committed, so it cannot drift from its generator. To retune it, edit coordinates in the 1024pt design space, run `swift scripts/make-icon.swift`, and *look at the PNG* — the geometry is easy to get subtly wrong (the handle detached from the cup on the first pass and only reading the render caught it).

### Timer detail

The countdown timer is added via `RunLoop.main.add(tick, forMode: .common)`, not `Timer.scheduledTimer`, so it keeps ticking while the menu is open and the runloop is in event-tracking mode.

## Verifying UI changes

There is no automated UI test and no GUI-vision tool available here. For behavior, compile `CaffeineController.swift` against a throwaway driver in a scratch directory and count `onStateChange` calls — and run the same driver against the pre-change commit as a control, since a driver that reports success everywhere proves nothing. For anything visual, ask the user to look; do not screenshot their live desktop.

Drivers spawn real `caffeinate` children. Reap them, and check with `pgrep -fl caffeinate | grep -- ' -w '` — unrelated `caffeinate -i -t 300` processes belong to other tooling and are not yours.

## Design docs

`docs/superpowers/specs/` holds the design rationale; `docs/superpowers/plans/` holds the implementation plan with the real source spliced into its task listings. If you change `CaffeineController` or `MenuController`, the plan's listings go stale — re-splice them.
