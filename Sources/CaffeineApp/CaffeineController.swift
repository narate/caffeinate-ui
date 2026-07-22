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
        try spawn()
        state = .active(until: until)
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
        // keep claiming the Mac is being held awake.
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                self.process = nil
                self.state = .idle
            }
        }
        try child.run()
        self.process = child
    }
}
