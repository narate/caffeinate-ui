import AppKit

if CommandLine.arguments.contains("--self-check") {
    // Non-zero on failure, so bundle.sh's `set -e` and any future CI treat a
    // failed check as a failed run rather than a crash with no explanation.
    exit(runSelfCheck() ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, menubar only

let controller = CaffeineController()
let menuController = MenuController(controller: controller)
menuController.install()

app.run()
