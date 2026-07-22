import Foundation

// The project's unit tests.
//
// These are not written against XCTest or swift-testing because neither can be
// built on this machine — see CLAUDE.md. What follows is the smallest harness
// that still behaves like a test runner rather than a tripwire: every case has a
// name, every case runs even after an earlier one fails, and the exit code
// reports the result.
//
// The checks are ordinary comparisons rather than `precondition`, so nothing
// here can be optimized out of the release binary. `scripts/bundle.sh` runs this
// against the release build for exactly that reason.

/// Collects results so a run reports every failure, not just the first.
struct TestRunner {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    /// Records a boolean expectation.
    mutating func check(_ name: String, _ condition: Bool, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("\(name) — line \(line)")
        }
    }

    /// Records an equality expectation, reporting both values on failure.
    /// Worth the overload: "expected 2700, got 45" localises a bug far faster
    /// than "parseDuration(45m) failed".
    mutating func check<T: Equatable>(
        _ name: String, _ actual: T, _ expected: T, line: UInt = #line
    ) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(name) — expected \(expected), got \(actual) — line \(line)")
        }
    }
}

// MARK: - caffeinateArgs

func testCaffeinateArgs(_ t: inout TestRunner) {
    t.check("argv orders flags -d -i regardless of insertion order",
            try! caffeinateArgs(flags: [.idle, .display], watching: 42),
            ["-d", "-i", "-w", "42"])
    t.check("argv orders flags -m -s regardless of insertion order",
            try! caffeinateArgs(flags: [.system, .disk], watching: 7),
            ["-m", "-s", "-w", "7"])
    t.check("argv emits all four flags in order",
            try! caffeinateArgs(flags: Set(SleepFlag.allCases), watching: 1),
            ["-d", "-i", "-m", "-s", "-w", "1"])

    // Checked across all 15 non-empty subsets rather than a hand-picked case, so
    // a future edit cannot quietly break either invariant for some combination
    // the explicit cases above do not cover.
    let all = SleepFlag.allCases
    var crashSafetyHolds = true
    var noTimeoutFlag = true
    for mask in 1..<(1 << all.count) {
        let subset = Set(all.enumerated()
            .filter { mask & (1 << $0.offset) != 0 }
            .map(\.element))
        let args = try! caffeinateArgs(flags: subset, watching: 4242)
        if args.suffix(2) != ["-w", "4242"] { crashSafetyHolds = false }
        if args.contains("-t") { noTimeoutFlag = false }
    }
    t.check("crash safety: -w <pid> is last for every flag subset", crashSafetyHolds)
    t.check("the deadline is ours: no -t for any flag subset", noTimeoutFlag)
}

func testEmptyFlagsRejected(_ t: inout TestRunner) {
    // Per `man caffeinate`: "If no assertion flags are specified, caffeinate
    // creates an assertion to prevent idle sleep." So an unflagged child would
    // hold the Mac awake on an implicit idle assertion while the Prevent submenu
    // showed every box unchecked — the UI would understate what is happening.
    do {
        _ = try caffeinateArgs(flags: [], watching: 1)
        t.check("empty flag set throws", false)
    } catch let error as CaffeineError {
        t.check("empty flag set throws noFlagsSelected", error, .noFlagsSelected)
    } catch {
        t.check("empty flag set throws CaffeineError, got \(error)", false)
    }
}

// MARK: - CaffeineController

func testRejectedStartLeavesControllerIdle(_ t: inout TestRunner) {
    // `isActive` must never be true unless a child is actually running — the
    // invariant the app's honesty rests on. Safe to run here: the empty flag set
    // throws inside `caffeinateArgs`, which `spawn` calls before it builds or
    // runs a `Process`, so nothing is spawned and no assertion is held.
    let controller = CaffeineController()
    controller.flags = []
    do {
        try controller.start(duration: 900)
        t.check("start with no flags throws", false)
    } catch {
        t.check("rejected start leaves state idle", controller.state, .idle)
        t.check("rejected start leaves isActive false", !controller.isActive)
    }
}

// MARK: - formatRemaining

func testFormatRemaining(_ t: inout TestRunner) {
    t.check("zero",              formatRemaining(0),    "0s")
    t.check("negative clamps",   formatRemaining(-5),   "0s")
    t.check("seconds",           formatRemaining(59),   "59s")
    t.check("rounds up to 1m",   formatRemaining(59.6), "1m")
    t.check("minute boundary",   formatRemaining(60),   "1m")
    t.check("just under an hour", formatRemaining(3599), "59m")
    t.check("hour zero-pads",    formatRemaining(3600), "1h 00m")
    t.check("hours and minutes", formatRemaining(3900), "1h 05m")
}

// MARK: - parseDuration

func testParseDuration(_ t: inout TestRunner) {
    t.check("seconds suffix",    parseDuration("30s"),    30)
    t.check("minutes suffix",    parseDuration("45m"),    2700)
    t.check("hours suffix",      parseDuration("2h"),     7200)
    t.check("days suffix",       parseDuration("1d"),     86400)
    t.check("bare number is minutes", parseDuration("45"), 2700)
    t.check("case-insensitive",  parseDuration("2H"),     7200)
    t.check("whitespace stripped throughout", parseDuration(" 2 h "), 7200)
    t.check("lower bound",       parseDuration("1s"),     1)
    t.check("upper bound",       parseDuration("7d"),     604800)
    t.check("upper bound via another unit", parseDuration("10080m"), 604800)

    t.check("past the bound",    parseDuration("8d"),     nil)
    t.check("past the bound via another unit", parseDuration("10081m"), nil)
    t.check("zero seconds",      parseDuration("0s"),     nil)
    t.check("zero",              parseDuration("0"),      nil)
    t.check("negative",          parseDuration("-5m"),    nil)
    t.check("empty",             parseDuration(""),       nil)
    t.check("whitespace only",   parseDuration("   "),    nil)
    t.check("not a number",      parseDuration("abc"),    nil)
    t.check("suffix with no magnitude", parseDuration("m"), nil)
    t.check("decimal",           parseDuration("45.5"),   nil)
    t.check("decimal with suffix", parseDuration("1.5h"), nil)
    t.check("unknown suffix",    parseDuration("45x"),    nil)
    t.check("exponent notation", parseDuration("1e3"),    nil)
    t.check("overflows Int",     parseDuration("99999999999999999999d"), nil)
}

// MARK: - Entry point

/// Runs every test. Returns true if all passed. Invoked by `--self-check`.
func runSelfCheck() -> Bool {
    var t = TestRunner()

    testCaffeinateArgs(&t)
    testEmptyFlagsRejected(&t)
    testRejectedStartLeavesControllerIdle(&t)
    testFormatRemaining(&t)
    testParseDuration(&t)

    guard t.failures.isEmpty else {
        print("self-check FAILED — \(t.failures.count) of \(t.passed + t.failures.count):")
        for failure in t.failures { print("  ✗ \(failure)") }
        return false
    }
    print("self-check ok — \(t.passed) checks passed")
    return true
}
