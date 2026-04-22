import SwiftUI

@main
struct TidyMountApp: App {
    @StateObject private var mountManager = MountManager()
    @Environment(\.openWindow) var openWindow
    
    var body: some Scene {
        MenuBarExtra {
            MainMenuView(manager: mountManager)
            
            Divider()
            
            Button("About TidyMount") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "about")
            }
        } label: {
            if let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                let _ = image.isTemplate = true
                Image(nsImage: image)
            } else {
                Image(systemName: "externaldrive.badge.plus")
            }
        }
        .menuBarExtraStyle(.window)
        
        Window("About TidyMount", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        
        Settings {
            SettingsView(manager: mountManager)
                .frame(width: 450, height: 400)
                .navigationTitle("TidyMount")
        }
        
        Window("TidyMount Settings", id: "settings") {
            SettingsView(manager: mountManager)
                .frame(width: 450, height: 400)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
