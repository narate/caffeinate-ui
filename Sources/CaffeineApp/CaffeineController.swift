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
