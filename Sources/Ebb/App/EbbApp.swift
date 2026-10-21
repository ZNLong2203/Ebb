import SwiftUI

@main
struct EbbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Ebb", id: "main") {
            ContentView(model: model)
                .onAppear {
                    #if DEBUG
                    model.installDebugHook()
                    #endif
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Home Folder") { model.scan(root: NSHomeDirectory()) }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isScanning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
