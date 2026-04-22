import SwiftUI
import ServiceManagement

struct MainMenuView: View {
    @ObservedObject var manager: MountManager
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TidyMount")
                    .font(.headline)
                Spacer()
                if manager.isCheckingAll {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                if manager.shares.isEmpty {
                    Text("No shares configured")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(manager.shares) { share in
                        let isMounted = manager.statuses[share.id] ?? false
                        let isMounting = manager.mountingIds.contains(share.id)
                        let isUnreachable = manager.unreachableIds.contains(share.id)
                        
                        HStack(spacing: 12) {
                            Image(systemName: isMounted ? "externaldrive.fill" : "externaldrive")
                                .font(.title3)
                                .foregroundColor(isMounted ? .blue : (isUnreachable ? .red : .secondary))
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(share.displayName)
                                    .font(.body)
                                    .fontWeight(.medium)
                                
                                if isMounting {
                                    Text("Mounting...").font(.caption).foregroundColor(.orange)
                                } else if isUnreachable && !isMounted {
                                    Text("Server unreachable").font(.caption).foregroundColor(.red)
                                } else {
                                    Text(isMounted ? "Connected" : "Disconnected").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            if isMounted {
                                Button("Unmount") {
                                    manager.unmount(share: share)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button("Mount") {
                                    Task {
                                        await manager.mount(share: share)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isMounting)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                manager.removeShare(share: share)
                            } label: {
                                Label("Delete Share", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Button(action: {
                    Task {
                        await manager.checkAll(force: true)
                    }
                }) {
                    Label(manager.isCheckingAll ? "Checking..." : "Check All Now", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
                .disabled(manager.isCheckingAll)
                
                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }) {
                    Label("Settings...", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                
                Divider().padding(.vertical, 4)
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit TidyMount", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            }
            .padding(8)
        }
        .frame(width: 320)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 72))
                .foregroundColor(.blue)
                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
            
            VStack(spacing: 4) {
                Text("TidyMount")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Version 1.0")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text("© 2026 Jordan Petersen")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider().padding(.horizontal, 40)
            
            Text("A lightweight utility to keep your network shares tidy and always connected.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .foregroundColor(.primary.opacity(0.8))
            
            Link(destination: URL(string: "https://github.com/jp2014/TidyMount")!) {
                HStack {
                    Image(systemName: "link")
                    Text("Visit GitHub Repository")
                }
                .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 380, height: 420)
    }
}

struct SettingsView: View {
    @ObservedObject var manager: MountManager
    @State private var newURL: String = "smb://"
    @State private var newName: String = ""
    @State private var newUsername: String = ""
    @State private var newPassword: String = ""
    @State private var showingAddSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(header: Text("Network Shares")) {
                    if manager.shares.isEmpty {
                        Text("No shares added yet. Click 'Add Share' below.")
                            .foregroundColor(.secondary)
                            .font(.callout)
                            .padding(.vertical, 8)
                    }
                    
                    ForEach(manager.shares) { share in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(share.displayName).font(.headline)
                                Text(share.url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                if let user = share.username {
                                    Label(user, systemImage: "person.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            
                            Button(action: {
                                manager.removeShare(share: share)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete this share")
                            
                            Toggle("Auto", isOn: Binding(
                                get: { share.autoMount },
                                set: { newValue in
                                    if let index = manager.shares.firstIndex(where: { $0.id == share.id }) {
                                        manager.shares[index].autoMount = newValue
                                        manager.saveShares()
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help("Auto-mount this share")
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button(role: .destructive) {
                                manager.removeShare(share: share)
                            } label: {
                                Label("Delete Share", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: manager.removeShare)
                }
                
                Section(header: Text("General Settings")) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { manager.isLaunchingAtLogin },
                        set: { newValue in manager.setLaunchAtLogin(enabled: newValue) }
                    ))
                    
                    if #available(macOS 13.0, *) {
                        if SMAppService.mainApp.status == .requiresApproval {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Approval required in System Settings")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            
            HStack {
                Button(action: { showingAddSheet = true }) {
                    Label("Add Share", systemImage: "plus")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Spacer()
                
                Text("\(manager.shares.count) share\(manager.shares.count == 1 ? "" : "s") configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 450)
        .sheet(isPresented: $showingAddSheet) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Add New Share")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Enter the details for your network share.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Name").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                        TextField("e.g., My NAS", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                        TextField("smb://server/share", text: $newURL)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Examples:").font(.caption2).fontWeight(.bold)
                            Text("• smb://nas.local/movies").font(.caption2)
                            Text("• afp://192.168.1.50/backups").font(.caption2)
                        }
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    }
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Username (Optional)").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                            TextField("username", text: $newUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password (Optional)").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                            SecureField("password", text: $newPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    Text("Credentials will be stored securely in your macOS Keychain.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        showingAddSheet = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Spacer()
                    
                    Button("Add Share") {
                        if !newName.isEmpty && newURL.contains("://") {
                            manager.addShare(
                                url: newURL, 
                                name: newName, 
                                username: newUsername.isEmpty ? nil : newUsername, 
                                password: newPassword.isEmpty ? nil : newPassword
                            )
                            showingAddSheet = false
                            newName = ""
                            newURL = "smb://"
                            newUsername = ""
                            newPassword = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(newName.isEmpty || !newURL.contains("://"))
                }
            }
            .padding(32)
            .frame(width: 500)
        }
    }
}
