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
            // `force: true`: on success this lands on the same `.active(until:)`
            // we started from — same deadline, no error before or after — which
            // the no-op check would otherwise treat as nothing having happened.
            // But a flag change is exactly why `restart` ran, and the menu's
            // checkmarks are now stale, so the redraw must not be skipped.
            transition(to: .active(until: until), force: true)
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
    ///
    /// `force` overrides that skip for callers that know better: `restart(until:)`
    /// lands on the same state on success (a flag change without moving `state`
    /// or `lastError`), but the flags themselves changed and the menu's
    /// checkmarks are now stale, so the UI still needs to redraw even though
    /// nothing the no-op check inspects has moved.
    private func transition(to newState: State, error: Error? = nil, force: Bool = false) {
        let isNoOp = !force && newState == state && error == nil && lastError == nil
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
