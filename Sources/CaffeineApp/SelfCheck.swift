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
