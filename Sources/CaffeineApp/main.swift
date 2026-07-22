import AppKit

if CommandLine.arguments.contains("--self-check") {
    runSelfCheck()
    exit(0)
}
