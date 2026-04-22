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
        logger.info("Starting checkAll(force: \(force))...")
        if force { unreachableIds.removeAll() }
        
        for share in shares {
            logger.info("Checking share \(share.displayName, privacy: .public)...")
            await check(share: share)
        }
        
        logger.info("Finished checkAll.")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        isCheckingAll = false
    }
    
    func check(share: NetworkShare) async {
        let mounted = await worker.isMounted(shareURL: share.url, shareName: share.shareName)
        statuses[share.id] = mounted
        
        logger.info("Share \(share.displayName, privacy: .public): mounted=\(mounted), autoMount=\(share.autoMount), alreadyMounting=\(self.mountingIds.contains(share.id))")
        
        if !mounted && share.autoMount && !mountingIds.contains(share.id) {
            await mount(share: share)
        }
    }
    
    func mount(share: NetworkShare) async {
        guard !mountingIds.contains(share.id) else { 
            logger.info("Mount for \(share.displayName, privacy: .public) already in progress.")
            return 
        }
        
        mountingIds.insert(share.id)
        defer { mountingIds.remove(share.id) }
        
        logger.info("Starting mount for \(share.displayName, privacy: .public)")
        
        let password = KeychainHelper.getPassword(account: share.id.uuidString)
        let result = await worker.mount(shareURL: share.url, shareName: share.shareName, user: share.username, password: password)
        
        statuses[share.id] = (result == 0)
        if result == 0 {
            unreachableIds.remove(share.id)
            logger.info("Successfully mounted \(share.displayName, privacy: .public)")
        } else {
            logger.error("Mount for \(share.displayName, privacy: .public) failed with status: \(result)")
            
            // Exclude errors that mean the server IS reachable but something else is wrong
            let excludedErrors: Set<Int32> = [17, 2, 13, 1, -1073741275, -36, 60, -1]
            if !excludedErrors.contains(result) {
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
           var decoded = try? JSONDecoder().decode([NetworkShare].self, from: data) {
            
            // Migration: Check for passwords in URLs and move them to Keychain
            var needsResave = false
            for i in 0..<decoded.count {
                if let components = URLComponents(string: decoded[i].url), 
                   let password = components.password {
                    
                    // Move to Keychain
                    KeychainHelper.save(password: password, account: decoded[i].id.uuidString)
                    decoded[i].username = components.user
                    
                    // Sanitize URL
                    var cleanComponents = components
                    cleanComponents.user = nil
                    cleanComponents.password = nil
                    if let cleanURL = cleanComponents.url?.absoluteString {
                        decoded[i].url = cleanURL
                    }
                    needsResave = true
                }
            }
            
            self.shares = decoded
            if needsResave { saveShares() }
            logger.info("Loaded \(self.shares.count) shares from UserDefaults.")
        } else {
            logger.warning("Failed to load shares from UserDefaults.")
        }
    }
    
    func saveShares() {
        if let encoded = try? JSONEncoder().encode(shares) {
            UserDefaults.standard.set(encoded, forKey: "networkShares")
        }
    }
    
    func addShare(url: String, name: String, username: String? = nil, password: String? = nil) {
        var finalURL = url
        var finalUsername = username
        var finalPassword = password
        
        // If credentials are also in the URL, they take precedence for extraction
        if let components = URLComponents(string: url) {
            if components.user != nil { finalUsername = components.user }
            if components.password != nil { finalPassword = components.password }
            
            var cleanComponents = components
            cleanComponents.user = nil
            cleanComponents.password = nil
            if let u = cleanComponents.url?.absoluteString {
                finalURL = u
            }
        }
        
        let newShare = NetworkShare(url: finalURL, displayName: name, username: finalUsername)
        shares.append(newShare)
        
        if let pass = finalPassword {
            KeychainHelper.save(password: pass, account: newShare.id.uuidString)
        }
        
        saveShares()
        Task { await check(share: newShare) }
    }
    
    func removeShare(at offsets: IndexSet) {
        for index in offsets {
            let share = shares[index]
            KeychainHelper.delete(account: share.id.uuidString)
        }
        shares.remove(atOffsets: offsets)
        saveShares()
    }
    
    func removeShare(share: NetworkShare) {
        if let index = shares.firstIndex(where: { $0.id == share.id }) {
            KeychainHelper.delete(account: share.id.uuidString)
            shares.remove(at: index)
            saveShares()
        }
    }
    
    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            logger.info("Setting launch at login to: \(enabled). Current status: \(String(describing: service.status))")
            
            // If the requested state matches current status, do nothing
            let isCurrentlyEnabled = (service.status == .enabled || service.status == .requiresApproval)
            if isCurrentlyEnabled == enabled {
                logger.info("Current status already matches requested state.")
                return
            }
            
            do {
                if enabled {
                    try service.register()
                    logger.info("Successfully registered launch at login")
                } else {
                    try service.unregister()
                    logger.info("Successfully unregistered launch at login")
                }
            } catch {
                logger.error("Failed to set launch at login: \(error.localizedDescription)")
            }
            
            // Re-fetch status immediately
            updateLaunchAtLoginStatus()
            
            // Sometimes it takes a moment for the system to update the status,
            // so we'll check again in a second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.updateLaunchAtLoginStatus()
            }
        }
    }
    
    func updateLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            logger.info("Current launch at login status: \(String(describing: status))")
            isLaunchingAtLogin = (status == .enabled || status == .requiresApproval)
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

        let volumeTask = Task {
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey, .volumeIsLocalKey], options: []) ?? []
        }

        // Timeout after 10 seconds for the volume list itself
        let mountedVolumes = await withTaskGroup(of: [URL].self) { group -> [URL] in
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return []
            }
            group.addTask {
                return await volumeTask.value
            }
            if let first = await group.next() {
                group.cancelAll()
                return first
            }
            return []
        }

        if mountedVolumes.isEmpty {
            // Check if it was a timeout or just empty
            // If it was a timeout, volumeTask is still running.
        }

        for url in mountedVolumes {
            if matchesShareName(volumeName: url.lastPathComponent, shareName: shareName) {
                let values = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey])
                if let remountURL = values?.volumeURLForRemounting?.absoluteString,
                   let normalizedRemount = normalizeURL(remountURL) {
                    if normalizedRemount == target {
                        // Volume found, now check if it is responsive
                        let responsive = await isResponsive(url: url)
                        if !responsive {
                            logger.warning("Volume \(shareName, privacy: .public) found in list but is UNRESPONSIVE.")
                        }
                        return responsive
                    }
                }
            }
        }
        return false
    }
    
    private func isResponsive(url: URL) async -> Bool {
        let path = url.path
        let task = Task.detached { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/df")
            process.arguments = ["-h", path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                
                // Wait for up to 30 seconds
                let timeout = Date().addingTimeInterval(30.0)
                while process.isRunning && Date() < timeout {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                
                if process.isRunning {
                    process.terminate()
                    self.logger.error("Liveness check for \(path, privacy: .public) TIMED OUT.")
                    return false
                }
                
                let status = process.terminationStatus
                if status != 0 {
                    self.logger.error("Liveness check for \(path, privacy: .public) FAILED with status \(status).")
                }
                return status == 0
            } catch {
                return false
            }
        }
        
        return await task.value
    }
    
    func mount(shareURL: String, shareName: String, user: String?, password: String?) async -> Int32 {
        var urlString = shareURL
        if URL(string: urlString) == nil {
            urlString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
        }
        
        guard let url = URL(string: urlString) else {
            logger.error("Failed to parse URL: \(shareURL, privacy: .public)")
            return 22 // EINVAL
        }
        
        var cleanURL = url
        // Ensure the URL used for mounting is clean of any embedded credentials
        if let components = URLComponents(string: urlString) {
            var cleanComponents = components
            cleanComponents.user = nil
            cleanComponents.password = nil
            if let u = cleanComponents.url {
                cleanURL = u
            }
        }
        
        // 1. Safe pre-check cleanup
        await cleanupStaleMount(shareName: shareName, forceUnmount: false)
        
        // 2. Attempt mount
        var (status, _) = await mountSync(url: cleanURL, user: user, password: password)
        
        // 3. Handle EEXIST (status 17) or Generic Error (status -1)
        if status == 17 || status == -1 {
            logger.warning("Mount blocked by status \(status) for \(shareName, privacy: .public). Attempting surgical cleanup...")
            await cleanupStaleMount(shareName: shareName, forceUnmount: true)
            (status, _) = await mountSync(url: cleanURL, user: user, password: password)
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
    
    private func mountSync(url: URL, user: String?, password: String?) async -> (Int32, [URL]?) {
        var mountpoints: Unmanaged<CFArray>?
        
        let openOptions = ["UIOption": "NoUI"] as NSMutableDictionary
        let mountOptions = ["MountFlags": 0] as NSMutableDictionary
        
        let status = NetFSMountURLSync(
            url as CFURL,
            nil,
            user as CFString?,
            password as CFString?,
            openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary,
            &mountpoints
        )
        
        let urls = (mountpoints?.takeRetainedValue() as? [String])?.map { URL(fileURLWithPath: $0) }
        return (status, urls)
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
        
        // Normalize credentials: remove them
        components.user = nil
        components.password = nil
        
        // Normalize query and fragment: remove them
        components.queryItems = nil
        components.fragment = nil
        
        // Normalize hostname: remove .local suffix if present
        if let host = components.host, host.lowercased().hasSuffix(".local") {
            components.host = String(host.dropLast(6))
        }
        
        // Normalize path: strip SMB parameters (everything after ;)
        if let semicolonIndex = components.path.firstIndex(of: ";") {
            components.path = String(components.path[..<semicolonIndex])
        }
        
        var normalized = components.url?.absoluteString ?? urlString
        // Remove trailing slashes
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
