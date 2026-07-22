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

    // Design invariants, checked across all 15 non-empty subsets rather than a
    // hand-picked case, so a future edit cannot quietly break them for some
    // flag combination the explicit assertions above do not cover.
    let all = SleepFlag.allCases
    for mask in 1..<(1 << all.count) {
        let subset = Set(all.enumerated()
            .filter { mask & (1 << $0.offset) != 0 }
            .map(\.element))
        let args = try! caffeinateArgs(flags: subset, watching: 4242)
        // Crash safety: -w <our pid> holds for every flag combination.
        precondition(args.suffix(2) == ["-w", "4242"])
        // The deadline is MenuController's Timer alone, never caffeinate's.
        precondition(!args.contains("-t"))
    }

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

    // A rejected start must leave the controller observably idle: `isActive`
    // must never be true unless a child is actually running, which is the
    // invariant the app's honesty rests on. Safe to run here — the empty flag
    // set throws inside `caffeinateArgs`, which `spawn` calls before it builds
    // or runs a `Process`, so nothing is spawned and no assertion is held.
    let controller = CaffeineController()
    controller.flags = []
    do {
        try controller.start(duration: 900)
        preconditionFailure("empty flag set must not start a session")
    } catch {
        precondition(controller.state == .idle)
        precondition(!controller.isActive)
    }

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

    print("self-check ok")
}
