import SwiftUI

struct MainMenuView: View {
    @ObservedObject var manager: MountManager
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TidyMount")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)
            
            Divider().padding(.vertical, 8)
            
            if manager.shares.isEmpty {
                Text("No shares configured")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(manager.shares) { share in
                    let isMounted = manager.statuses[share.id] ?? false
                    let isMounting = manager.mountingIds.contains(share.id)
                    let isUnreachable = manager.unreachableIds.contains(share.id)
                    
                    HStack {
                        Image(systemName: isMounted ? "externaldrive.fill" : "externaldrive")
                            .foregroundColor(isMounted ? .blue : (isUnreachable ? .red : .secondary))
                        
                        VStack(alignment: .leading) {
                            Text(share.displayName)
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
                                manager.mount(share: share)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isMounting)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            
            Divider().padding(.vertical, 8)
            
            Button(action: {
                manager.checkAll(forceMount: true)
            }) {
                HStack {
                    if manager.isCheckingAll {
                        ProgressView().controlSize(.small)
                    }
                    Text(manager.isCheckingAll ? "Checking..." : "Check All Now")
                }
            }
            .padding(.horizontal)
            .disabled(manager.isCheckingAll)
            
            Button("Settings...") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            Divider()
            
            Button("Quit TidyMount") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 250)
    }
}

struct SettingsView: View {
    @ObservedObject var manager: MountManager
    @State private var newURL: String = "smb://"
    @State private var newName: String = ""
    @State private var showingAddSheet = false
    
    var body: some View {
        VStack {
            List {
                Section(header: Text("Network Shares")) {
                    ForEach(manager.shares) { share in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(share.displayName).font(.headline)
                                Text(share.url).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { share.autoMount },
                                set: { newValue in
                                    if let index = manager.shares.firstIndex(where: { $0.id == share.id }) {
                                        manager.shares[index].autoMount = newValue
                                        manager.saveShares()
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                        }
                    }
                    .onDelete(perform: manager.removeShare)
                }
                
                Section(header: Text("General Settings")) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { manager.isLaunchingAtLogin },
                        set: { _ in manager.toggleLaunchAtLogin() }
                    ))
                }
            }
            
            HStack {
                Button(action: { showingAddSheet = true }) {
                    Label("Add Share", systemImage: "plus")
                }
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showingAddSheet) {
            VStack(spacing: 20) {
                Text("Add New Share").font(.headline)
                
                TextField("Display Name (e.g., 12tb)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                
                TextField("SMB URL (smb://server/share)", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button("Cancel") {
                        showingAddSheet = false
                    }
                    Spacer()
                    Button("Add") {
                        if !newName.isEmpty && newURL.starts(with: "smb://") {
                            manager.addShare(url: newURL, name: newName)
                            showingAddSheet = false
                            newName = ""
                            newURL = "smb://"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }
}
