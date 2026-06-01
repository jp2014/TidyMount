import Foundation
import CryptoKit
import IOKit
import os

struct SecureVault {
    static let service = "com.jordanpetersen.TidyMount"
    private static let fileName = "vault.bin"
    private static let logger = Logger(subsystem: "com.tidymount", category: "SecureVault")
    private static let lock = NSLock()
    
    private static var vaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent(service)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }
    
    private static func getMasterKey() -> SymmetricKey? {
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        
        let platformExpert = IOServiceGetMatchingService(mainPort, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        
        guard let uuid = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return nil
        }
        
        let salt = "com.jordanpetersen.TidyMount.salt.v1"
        let keyData = Data((uuid + salt).utf8)
        let hashed = SHA256.hash(data: keyData)
        return SymmetricKey(data: hashed)
    }
    
    // MARK: - API
    
    static func save(password: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        logger.info("Saving password to vault for account: \(account, privacy: .public)")
        var vault = loadVault()
        vault[account] = password
        saveVault(vault)
    }
    
    static func getPassword(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let vault = loadVault()
        return vault[account]
    }
    
    static func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        logger.info("Deleting password from vault for account: \(account, privacy: .public)")
        var vault = loadVault()
        vault.removeValue(forKey: account)
        saveVault(vault)
    }
    
    private static func loadVault() -> [String: String] {
        guard let key = getMasterKey() else {
            logger.error("Failed to derive Master Key")
            return [:]
        }
        guard let data = try? Data(contentsOf: vaultURL) else { return [:] }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return try JSONDecoder().decode([String: String].self, from: decryptedData)
        } catch {
            logger.error("Failed to load/decrypt vault: \(error.localizedDescription)")
            return [:]
        }
    }
    
    private static func saveVault(_ vault: [String: String]) {
        guard let key = getMasterKey() else { return }
        do {
            let data = try JSONEncoder().encode(vault)
            let sealedBox = try AES.GCM.seal(data, using: key)
            if let combined = sealedBox.combined {
                try combined.write(to: vaultURL)
            }
        } catch {
            logger.error("Failed to save/encrypt vault: \(error.localizedDescription)")
        }
    }
}
