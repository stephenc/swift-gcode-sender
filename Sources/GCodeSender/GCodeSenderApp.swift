import SwiftUI

@main
struct GCodeSenderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open G-code or SVG…") { model.isImporterPresented = true }
                    .keyboardShortcut("o")
            }
        }
        Settings { SettingsView().environmentObject(model).frame(width: 520, height: 420) }
    }
}
