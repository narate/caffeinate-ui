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

    print("self-check ok")
}
