import Foundation
import NetFS
import SwiftUI
import AppKit
import ServiceManagement
import Combine
import Network
import os

class MountManager: ObservableObject {
    @Published var shares: [NetworkShare] = []
    @Published var statuses: [UUID: Bool] = [:]
    @Published var mountingIds: Set<UUID> = []
    @Published var unreachableIds: Set<UUID> = []
    @Published var isCheckingAll: Bool = false
    @Published var isLaunchingAtLogin: Bool = false
    
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var cancellableTimer: AnyCancellable?
    private let pathMonitor = NWPathMonitor()
    private let logger = Logger(subsystem: "com.tidymount", category: "MountManager")
    
    init() {
        logger.info("MountManager initializing...")
        loadShares()
        checkAll()
        setupListeners()
        updateLaunchAtLoginStatus()
        
        cancellableTimer = timer.sink { [weak self] _ in
            self?.checkAll()
        }
        
        pathMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                self?.logger.info("Network connection change detected, checking mounts...")
                DispatchQueue.main.async {
                    self?.checkAll()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .background))
        logger.info("MountManager initialized!")
    }
    
    func setupListeners() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logger.info("Mac woke from sleep, checking mounts...")
            self?.checkAll()
        }
        
        notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatuses()
        }
        
        notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logger.info("A volume was unmounted, checking if we need to reconnect...")
            self?.checkAll()
        }
    }
    
    func updateStatuses() {
        for share in shares {
            let mounted = isMounted(share: share)
            DispatchQueue.main.async {
                self.statuses[share.id] = mounted
            }
        }
    }
    
    func updateLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            isLaunchingAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
    
    func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                updateLaunchAtLoginStatus()
            } catch {
                logger.error("Failed to toggle launch at login: \(error.localizedDescription)")
            }
        }
    }
    
    func loadShares() {
        if let data = UserDefaults.standard.data(forKey: "networkShares"),
           let decoded = try? JSONDecoder().decode([NetworkShare].self, from: data) {
            self.shares = decoded
        }
    }
    
    func saveShares() {
        if let encoded = try? JSONEncoder().encode(shares) {
            UserDefaults.standard.set(encoded, forKey: "networkShares")
        }
    }
    
    func addShare(url: String, name: String) {
        let newShare = NetworkShare(url: url, displayName: name)
        shares.append(newShare)
        saveShares()
        check(share: newShare)
    }
    
    func removeShare(at offsets: IndexSet) {
        shares.remove(atOffsets: offsets)
        saveShares()
    }
    
    func checkAll(forceMount: Bool = false) {
        logger.info("Check all shares triggered (forceMount: \(forceMount))...")
        DispatchQueue.main.async {
            self.isCheckingAll = true
            if forceMount {
                self.unreachableIds.removeAll()
            }
        }
        
        for share in shares {
            check(share: share)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isCheckingAll = false
        }
    }
    
    func check(share: NetworkShare) {
        // Silently scrub any empty stale directories for this share in the background
        DispatchQueue.global(qos: .background).async {
            self.cleanupStaleMount(for: share, forceUnmountActive: false)
        }
        
        let mounted = isMounted(share: share)
        logger.info("Share '\(share.displayName)' isMounted: \(mounted)")
        DispatchQueue.main.async {
            self.statuses[share.id] = mounted
        }
        
        if !mounted && share.autoMount && !mountingIds.contains(share.id) {
            // If not mounted and auto-mount is on, try to mount
            mount(share: share)
        }
    }
    
    func isMounted(share: NetworkShare) -> Bool {
        let mountedVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.isVolumeKey], options: []) ?? []
        let sharePath = "/Volumes/\(share.shareName)"
        
        return mountedVolumes.contains(where: { $0.path == sharePath })
    }
    
    func cleanupStaleMount(for share: NetworkShare, forceUnmountActive: Bool) {
        let volumeName = share.shareName
        let volumesDir = "/Volumes"
        
        let mountedVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.isVolumeKey], options: []) ?? []
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: volumesDir)
            
            // Find anything that looks like "ShareName" or "ShareName-1", "ShareName-2", etc.
            let matches = contents.filter { name in
                if name == volumeName { return true }
                if name.hasPrefix("\(volumeName)-") {
                    let suffix = name.replacingOccurrences(of: "\(volumeName)-", with: "")
                    return Int(suffix) != nil
                }
                return false
            }
            
            for match in matches {
                let fullPath = "\(volumesDir)/\(match)"
                let isActuallyMounted = mountedVolumes.contains(where: { $0.path == fullPath })
                
                if isActuallyMounted && !forceUnmountActive {
                    logger.info("Cleanup: Skipping active mount at \(fullPath)")
                    continue
                }
                
                logger.info("Aggressive Cleanup: Targeting \(fullPath)")
                
                // 1. Forcefully unmount just in case
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                process.arguments = ["unmount", "force", fullPath]
                try? process.run()
                process.waitUntilExit()
                
                // 2. Safe deletion (only if empty to prevent data loss)
                if FileManager.default.fileExists(atPath: fullPath) {
                    do {
                        let innerContents = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                        if innerContents.isEmpty {
                            try FileManager.default.removeItem(atPath: fullPath)
                            logger.info("Successfully removed empty directory: \(fullPath)")
                        } else {
                            logger.warning("WARNING: Directory \(fullPath) is NOT empty! Skipping deletion to prevent data loss.")
                        }
                    } catch {
                        logger.error("FileManager failed to check/remove \(fullPath): \(error.localizedDescription)")
                        // Safe fallback: rmdir only deletes if empty
                        let rmProcess = Process()
                        rmProcess.executableURL = URL(fileURLWithPath: "/bin/rmdir")
                        rmProcess.arguments = [fullPath]
                        try? rmProcess.run()
                        rmProcess.waitUntilExit()
                    }
                }
            }
        } catch {
            logger.error("Failed to read /Volumes for cleanup: \(error.localizedDescription)")
        }
    }
    
    func mount(share: NetworkShare) {
        guard let url = URL(string: share.url) else { return }
        
        DispatchQueue.main.async {
            self.mountingIds.insert(share.id)
        }
        
        // Safety timeout for the mounting process (30 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if self.mountingIds.contains(share.id) {
                self.logger.warning("Mount process for \(share.displayName) timed out.")
                self.mountingIds.remove(share.id)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            // AGGRESSIVE CLEANUP: Force unmount and clear EVERYTHING matching the name before mounting
            self.cleanupStaleMount(for: share, forceUnmountActive: true)
            
            let mountPathString = "/Volumes/\(share.shareName)"
            
            // Final check: if a directory still exists with the EXACT name, do not mount.
            // This prevents the -1 duplication.
            if FileManager.default.fileExists(atPath: mountPathString) {
                self.logger.error("Cleanup failed to clear \(mountPathString). Aborting mount to prevent duplication.")
                DispatchQueue.main.async {
                    self.mountingIds.remove(share.id)
                }
                return
            }
            
            let openOptions = NSMutableDictionary()
            openOptions["UIOption"] = "NoUI"
            let mountOptions = NSMutableDictionary()
            mountOptions["MountFlags"] = 0
            
            var requestID: AsyncRequestID?
            
            self.logger.info("Attempting to mount \(share.url) directly to \(mountPathString)...")
            
            DispatchQueue.main.async {
                let status = NetFSMountURLAsync(
                    url as CFURL,
                    nil,
                    nil,
                    nil,
                    openOptions as CFMutableDictionary,
                    mountOptions as CFMutableDictionary,
                    &requestID,
                    DispatchQueue.main
                ) { status, requestID, mountpoints in
                    DispatchQueue.main.async {
                        self.mountingIds.remove(share.id)
                        if status == 0 {
                            self.logger.info("Successfully mounted: \(share.displayName)")
                            self.statuses[share.id] = true
                            self.unreachableIds.remove(share.id)
                        } else {
                            self.logger.error("Failed to mount \(share.displayName) with status: \(status)")
                            self.statuses[share.id] = false
                            if status != -1073741275 && status != 60 && status != -36 {
                                self.unreachableIds.insert(share.id)
                            }
                        }
                    }
                }
                
                if status != 0 {
                    self.logger.error("Failed to initiate mount for \(share.displayName): \(status)")
                    DispatchQueue.main.async {
                        self.mountingIds.remove(share.id)
                        self.unreachableIds.insert(share.id)
                    }
                }
            }
        }
    }
    
    func unmount(share: NetworkShare) {
        let volumeName = share.shareName
        let mountedVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.isVolumeKey], options: []) ?? []
        
        let matches = mountedVolumes.filter { url in
            let name = url.lastPathComponent
            if name == volumeName { return true }
            if name.hasPrefix("\(volumeName)-") {
                let suffix = name.replacingOccurrences(of: "\(volumeName)-", with: "")
                return Int(suffix) != nil
            }
            return false
        }
        
        logger.info("Unmounting \(share.displayName)...")
        for url in matches {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                logger.error("Failed to unmount \(url.path): \(error.localizedDescription)")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                process.arguments = ["unmount", "force", url.path]
                try? process.run()
            }
        }
        
        DispatchQueue.main.async {
            self.statuses[share.id] = false
        }
    }

}
