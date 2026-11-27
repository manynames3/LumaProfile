import SwiftUI

@main
enum LumaProfileLauncher {
    static func main() {
        if CommandLine.arguments.contains(DisplayGuardAgent.argument) {
            DisplayGuardAgent.runForever()
        }
        MainActor.assumeIsolated {
            LumaProfileApp.main()
        }
    }
}

@MainActor
struct LumaProfileApp: App {
    @NSApplicationDelegateAdaptor(LumaProfileAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("LumaProfile", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
