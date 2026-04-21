import SwiftUI

@main
struct TidyMountApp: App {
    @StateObject private var mountManager = MountManager()
    
    var body: some Scene {
        MenuBarExtra {
            MainMenuView(manager: mountManager)
        } label: {
            Image(systemName: "externaldrive.badge.plus")
        }
        .menuBarExtraStyle(.menu)
        
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
