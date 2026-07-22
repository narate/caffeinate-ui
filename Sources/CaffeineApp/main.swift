import AppKit

if CommandLine.arguments.contains("--self-check") {
    runSelfCheck()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, menubar only

let controller = CaffeineController()
let menuController = MenuController(controller: controller)
menuController.install()

app.run()
