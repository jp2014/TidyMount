import Foundation
import NetFS
import SwiftUI
import AppKit
import ServiceManagement
import Combine
import Network
import os

@MainActor
class MountManager: ObservableObject {
    @Published var shares: [NetworkShare] = []
    @Published var statuses: [UUID: Bool] = [:]
    @Published var mountingIds: Set<UUID> = []
    @Published var unreachableIds: Set<UUID> = []
    @Published var isCheckingAll: Bool = false
    @Published var isLaunchingAtLogin: Bool = false
    
    private let logger = Logger(subsystem: "com.tidymount", category: "MountManager")
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var cancellableTimer: AnyCancellable?
    private let pathMonitor = NWPathMonitor()
    
    private var lastCheckTime: Date = .distantPast
    private var checkTask: Task<Void, Never>?
    private let worker = MountWorker()
    
    init() {
        logger.info("MountManager initializing...")
        loadShares()
        setupListeners()
        updateLaunchAtLoginStatus()
        
        cancellableTimer = timer.sink { [weak self] _ in
            self?.debouncedCheckAll()
        }
        
        pathMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                DispatchQueue.main.async {
                    self?.debouncedCheckAll()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .background))
        
        // Initial check
        Task {
            await checkAll(force: true)
        }
        logger.info("MountManager initialized!")
    }
    
    func setupListeners() {
        let nc = NSWorkspace.shared.notificationCenter
        
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.debouncedCheckAll()
            }
        }
        
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatuses()
            }
        }
        
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleUnmountNotification()
            }
        }
    }
    
    private func handleUnmountNotification() {
        // Ignore if any mount is in progress to prevent feedback loops
        guard mountingIds.isEmpty else {
            logger.info("Ignoring unmount notification: mount in progress.")
            return
        }
        debouncedCheckAll()
    }
    
    func debouncedCheckAll() {
        checkTask?.cancel()
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second debounce
            if !Task.isCancelled {
                await checkAll()
            }
        }
    }
    
    func updateStatuses() {
        Task {
            for share in shares {
                let mounted = await worker.isMounted(shareURL: share.url, shareName: share.shareName)
                statuses[share.id] = mounted
            }
        }
    }
    
    func checkAll(force: Bool = false) async {
        if isCheckingAll && !force { return }
        
        isCheckingAll = true
        if force { unreachableIds.removeAll() }
        
        for share in shares {
            await check(share: share)
        }
        
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        isCheckingAll = false
    }
    
    func check(share: NetworkShare) async {
        let mounted = await worker.isMounted(shareURL: share.url, shareName: share.shareName)
        statuses[share.id] = mounted
        
        if !mounted && share.autoMount && !mountingIds.contains(share.id) {
            await mount(share: share)
        }
    }
    
    func mount(share: NetworkShare) async {
        guard !mountingIds.contains(share.id) else { return }
        
        mountingIds.insert(share.id)
        defer { mountingIds.remove(share.id) }
        
        logger.info("Starting mount for \(share.displayName)")
        
        let result = await worker.mount(shareURL: share.url, shareName: share.shareName)
        
        statuses[share.id] = (result == 0)
        if result == 0 {
            unreachableIds.remove(share.id)
        } else {
            // Check if it's a "silent" error or real unreachability
            // E.g. -1073741275 is user cancelled/timeout
            if result != -1073741275 && result != 60 && result != -36 {
                unreachableIds.insert(share.id)
            }
        }
    }
    
    func unmount(share: NetworkShare) {
        Task {
            await worker.unmount(shareName: share.shareName)
            statuses[share.id] = false
        }
    }
    
    // MARK: - Settings & Persistence
    
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
        Task { await check(share: newShare) }
    }
    
    func removeShare(at offsets: IndexSet) {
        shares.remove(atOffsets: offsets)
        saveShares()
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
    
    func updateLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            isLaunchingAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Worker Actor

actor MountWorker {
    private let logger = Logger(subsystem: "com.tidymount", category: "MountWorker")
    
    private func matchesShareName(volumeName: String, shareName: String) -> Bool {
        let isExactMatch = volumeName.caseInsensitiveCompare(shareName) == .orderedSame
        let hasSuffixMatch = volumeName.lowercased().hasPrefix("\(shareName.lowercased())-") && Int(volumeName.replacingOccurrences(of: "\(shareName)-", with: "", options: .caseInsensitive)) != nil
        return isExactMatch || hasSuffixMatch
    }
    
    func isMounted(shareURL: String, shareName: String) async -> Bool {
        guard let target = normalizeURL(shareURL) else { return false }
        
        let mountedVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        
        for url in mountedVolumes {
            if matchesShareName(volumeName: url.lastPathComponent, shareName: shareName) {
                let values = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey])
                if let remountURL = values?.volumeURLForRemounting?.absoluteString,
                   let normalizedRemount = normalizeURL(remountURL) {
                    if normalizedRemount == target {
                        return true
                    }
                }
            }
        }
        return false
    }
    
    func mount(shareURL: String, shareName: String) async -> Int32 {
        guard let url = URL(string: shareURL) else { return -1 }
        
        // 1. Safe pre-check cleanup
        await cleanupStaleMount(shareName: shareName, forceUnmount: false)
        
        // 2. Attempt mount
        var (status, _) = await mountAsync(url: url)
        
        // 3. Handle EEXIST (status 17)
        if status == 17 {
            logger.warning("Mount blocked by EEXIST for \(shareName). Attempting surgical cleanup...")
            await cleanupStaleMount(shareName: shareName, forceUnmount: true)
            (status, _) = await mountAsync(url: url)
        }
        
        return status
    }
    
    func unmount(shareName: String) async {
        let volumesDir = "/Volumes"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: volumesDir)) ?? []
        let matches = contents.filter { matchesShareName(volumeName: $0, shareName: shareName) }
        
        for match in matches {
            let path = "\(volumesDir)/\(match)"
            if let dev = getDeviceID(path: path), let volDev = getDeviceID(path: volumesDir), dev != volDev {
                try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
            }
        }
    }
    
    // MARK: - Internal Helpers
    
    private func mountAsync(url: URL) async -> (Int32, [URL]?) {
        await withCheckedContinuation { continuation in
            var requestID: AsyncRequestID?
            let openOptions = ["UIOption": "NoUI"] as NSMutableDictionary
            let mountOptions = ["MountFlags": 0] as NSMutableDictionary
            
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil, nil, nil,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &requestID,
                nil // Uses a default concurrent queue
            ) { status, requestID, mountpoints in
                let urls = (mountpoints as? [String])?.map { URL(fileURLWithPath: $0) }
                continuation.resume(returning: (status, urls))
            }
            
            if status != 0 {
                continuation.resume(returning: (status, nil))
            }
        }
    }
    
    private func cleanupStaleMount(shareName: String, forceUnmount: Bool) async {
        let volumesDir = "/Volumes"
        guard let volumesDev = getDeviceID(path: volumesDir) else { return }
        
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: volumesDir)) ?? []
        let matches = contents.filter { matchesShareName(volumeName: $0, shareName: shareName) }
        
        for match in matches {
            let path = "\(volumesDir)/\(match)"
            guard let dev = getDeviceID(path: path) else { continue }
            
            let isActuallyMounted = (dev != volumesDev)
            
            if isActuallyMounted {
                if forceUnmount {
                    logger.info("Surgical Cleanup: Unmounting active drive at \(path)")
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
                } else {
                    continue
                }
            }
            
            // Ghost Check: Device ID must match /Volumes and directory must be empty
            if let postDev = getDeviceID(path: path), postDev == volumesDev {
                if isDirectoryEmpty(path: path) {
                    logger.info("Surgical Cleanup: Removing ghost folder \(path)")
                    try? FileManager.default.removeItem(atPath: path)
                } else {
                    logger.warning("Surgical Cleanup: \(path) matches Volumes device but is NOT empty. Skipping.")
                }
            }
        }
    }
    
    private func normalizeURL(_ urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else { return nil }
        components.user = nil
        components.password = nil
        var normalized = components.url?.absoluteString ?? urlString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }
    
    private func getDeviceID(path: String) -> dev_t? {
        var statbuf = stat()
        if stat(path, &statbuf) == 0 {
            return statbuf.st_dev
        }
        return nil
    }
    
    private func isDirectoryEmpty(path: String) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return contents.isEmpty
    }
}
