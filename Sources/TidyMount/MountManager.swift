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
    
    private var passwordCache: [UUID: String] = [:]
    private var checkCount: Int = 0
    
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
            guard let self = self else { return }
            self.checkCount += 1
            let force = self.checkCount % 10 == 0
            self.debouncedCheckAll(force: force)
        }
        
        pathMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                DispatchQueue.main.async {
                    self?.debouncedCheckAll(force: true)
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
                self?.debouncedCheckAll(force: true)
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
    
    func debouncedCheckAll(force: Bool = false) {
        checkTask?.cancel()
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second debounce
            if !Task.isCancelled {
                await checkAll(force: force)
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
        defer { isCheckingAll = false }
        
        logger.info("Starting checkAll(force: \(force))...")
        if force { unreachableIds.removeAll() }
        
        await withTaskGroup(of: Void.self) { group in
            for share in shares {
                group.addTask {
                    self.logger.info("Checking share \(share.displayName, privacy: .public)...")
                    await self.check(share: share)
                }
            }
        }
        
        logger.info("Finished checkAll.")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    
    func check(share: NetworkShare) async {
        let mounted = await worker.isMounted(shareURL: share.url, shareName: share.shareName)
        statuses[share.id] = mounted
        
        logger.info("Share \(share.displayName, privacy: .public): mounted=\(mounted), autoMount=\(share.autoMount), alreadyMounting=\(self.mountingIds.contains(share.id))")
        
        if !mounted && share.autoMount && !mountingIds.contains(share.id) && !unreachableIds.contains(share.id) {
            await mount(share: share)
        }
    }
    
    func mount(share: NetworkShare) async {
        guard !mountingIds.contains(share.id) else { 
            logger.info("Mount for \(share.displayName, privacy: .public) already in progress.")
            return 
        }

        mountingIds.insert(share.id)
        defer { 
            mountingIds.remove(share.id) 
            logger.info("Removed \(share.displayName, privacy: .public) from mountingIds (finished).")
        }

        logger.info("Starting mount for \(share.displayName, privacy: .public)")

        // 0. Pre-check reachability if it's an IP or hostname
        if let url = URL(string: share.url), let host = url.host {
            let reachable = await isHostReachable(host)
            if !reachable {
                logger.error("Host \(host, privacy: .public) is not reachable via TCP 445. Skipping mount.")
                unreachableIds.insert(share.id)
                statuses[share.id] = false
                return
            }
        }

        let password = passwordCache[share.id] ?? KeychainHelper.getPassword(account: share.id.uuidString)
        if let p = password {
            passwordCache[share.id] = p
        }
        
        logger.info("Calling worker.mount for \(share.displayName, privacy: .public)...")
        let result = await worker.mount(shareURL: share.url, shareName: share.shareName, user: share.username, password: password)
        logger.info("worker.mount returned \(result) for \(share.displayName, privacy: .public)")
        
        statuses[share.id] = (result == 0)
        if result == 0 {
            unreachableIds.remove(share.id)
            logger.info("Successfully mounted \(share.displayName, privacy: .public)")
        } else {
            logger.error("Mount for \(share.displayName, privacy: .public) failed with status: \(result)")
            
            // Exclude errors that mean the server IS reachable but something else is wrong
            let excludedErrors: Set<Int32> = [17, 2, 13, 1, -1073741275, -36, 60, 57, -1]
            if !excludedErrors.contains(result) {
                unreachableIds.insert(share.id)
            }
        }
    }
    
    private func isHostReachable(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 445, using: .tcp)
            var resumed = false
            
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 2.0)
            timer.setEventHandler {
                if !resumed {
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                }
                timer.cancel()
            }
            timer.resume()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        timer.cancel()
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if !resumed {
                        resumed = true
                        timer.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
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
            
            // Migration: Check for passwords in URLs and move them to secure vault
            var needsResave = false
            for i in 0..<decoded.count {
                if let components = URLComponents(string: decoded[i].url), 
                   let password = components.password {
                    
                    // Move to vault
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
            passwordCache[newShare.id] = pass
            KeychainHelper.save(password: pass, account: newShare.id.uuidString)
        }
        
        saveShares()
        Task { await check(share: newShare) }
    }
    
    func removeShare(at offsets: IndexSet) {
        for index in offsets {
            let share = shares[index]
            passwordCache.removeValue(forKey: share.id)
            KeychainHelper.delete(account: share.id.uuidString)
        }
        shares.remove(atOffsets: offsets)
        saveShares()
    }
    
    func removeShare(share: NetworkShare) {
        if let index = shares.firstIndex(where: { $0.id == share.id }) {
            passwordCache.removeValue(forKey: share.id)
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
            logger.info("Current launch at login status: <private>")
            isLaunchingAtLogin = (status == .enabled || status == .requiresApproval)
        }
    }
}

// MARK: - Worker

class MountWorker {
    private let logger = Logger(subsystem: "com.tidymount", category: "MountWorker")
    
    private func matchesShareName(volumeName: String, shareName: String) -> Bool {
        let isExactMatch = volumeName.caseInsensitiveCompare(shareName) == .orderedSame
        let hasSuffixMatch = volumeName.lowercased().hasPrefix("\(shareName.lowercased())-") && Int(volumeName.replacingOccurrences(of: "\(shareName)-", with: "", options: .caseInsensitive)) != nil
        return isExactMatch || hasSuffixMatch
    }
    func isMounted(shareURL: String, shareName: String) async -> Bool {
        guard let target = normalizeURL(shareURL) else { return false }

        let task = Task.detached {
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey, .volumeIsLocalKey], options: []) ?? []
        }

        let mountedVolumes = await withTaskGroup(of: [URL].self) { group -> [URL] in
            group.addTask {
                return await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return []
            }
            if let first = await group.next() {
                group.cancelAll()
                return first
            }
            return []
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
        let task = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/df")
            process.arguments = ["-h", path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
        
        // Timeout after 5 seconds for responsiveness check
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                return await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                task.cancel()
                return false
            }
            let result = await group.next()
            group.cancelAll()
            return result ?? false
        }
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
        logger.info("mountSync: Starting NetFSMountURLAsync for \(url.absoluteString, privacy: .public)")
        
        return await withTaskGroup(of: (Int32, [URL]?).self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let openOptions = ["UIOption": "NoUI"] as NSMutableDictionary
                    let mountOptions = ["MountFlags": 0] as NSMutableDictionary
                    var requestID: AsyncRequestID?
                    
                    var resumed = false
                    let status = NetFSMountURLAsync(
                        url as CFURL,
                        nil,
                        user as CFString?,
                        password as CFString?,
                        openOptions as CFMutableDictionary,
                        mountOptions as CFMutableDictionary,
                        &requestID,
                        DispatchQueue.global(qos: .background)
                    ) { status, _, mountpoints in
                        if !resumed {
                            resumed = true
                            let urls = (mountpoints as? [String])?.map { URL(fileURLWithPath: $0) }
                            continuation.resume(returning: (status, urls))
                        }
                    }
                    
                    if status != 0 {
                        if !resumed {
                            resumed = true
                            continuation.resume(returning: (status, nil))
                        }
                    }
                    
                    // Safety timeout for the continuation itself
                    DispatchQueue.global().asyncAfter(deadline: .now() + 65.0) {
                        if !resumed {
                            resumed = true
                            self.logger.error("mountSync: Continuation safety timeout triggered for \(url.host ?? "unknown")")
                            continuation.resume(returning: (60, nil))
                        }
                    }
                }
            }
            
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return (60, nil) // ETIMEDOUT
            }
            
            let result = await group.next()
            group.cancelAll()
            let finalResult = result ?? (60, nil)
            logger.info("mountSync finished with status \(finalResult.0)")
            return finalResult
        }
    }
    
    private func cleanupStaleMount(shareName: String, forceUnmount: Bool) async {
        let volumesDir = "/Volumes"
        guard let volumesDev = getDeviceID(path: volumesDir) else { 
            logger.error("cleanupStaleMount: Failed to get device ID for /Volumes")
            return 
        }
        
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: volumesDir)) ?? []
        let matches = contents.filter { matchesShareName(volumeName: $0, shareName: shareName) }
        
        logger.info("cleanupStaleMount for \(shareName, privacy: .public): matches=\(matches)")
        
        for match in matches {
            let path = "\(volumesDir)/\(match)"
            
            // Run inspection in a detached task to avoid hanging MainActor
            let (isActuallyMounted, deviceID) = await Task.detached(priority: .background) {
                guard let dev = self.getDeviceID(path: path) else { return (false, nil as dev_t?) }
                return (dev != volumesDev, dev)
            }.value
            
            if isActuallyMounted {
                if forceUnmount {
                    logger.info("Surgical Cleanup: Unmounting active drive at \(path)")
                    await Task.detached(priority: .background) {
                        try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
                    }.value
                } else {
                    logger.info("cleanupStaleMount: \(path) is actually mounted, skipping (forceUnmount=false)")
                    continue
                }
            }
            
            // Ghost Check: Device ID must match /Volumes and directory must be empty
            let isGhost = await Task.detached(priority: .background) {
                if let postDev = self.getDeviceID(path: path), postDev == volumesDev {
                    return self.isDirectoryEmpty(path: path)
                }
                return false
            }.value

            if isGhost {
                logger.info("Surgical Cleanup: Removing ghost folder \(path)")
                await Task.detached(priority: .background) {
                    try? FileManager.default.removeItem(atPath: path)
                }.value
            } else if deviceID == volumesDev {
                logger.warning("Surgical Cleanup: \(path) matches Volumes device but is NOT empty. Skipping.")
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
