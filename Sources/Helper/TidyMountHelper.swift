import Foundation

class TidyMountHelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // In a production environment, you should verify the code signature of the connecting process here.
        // For our purposes, we accept connections to our Mach service.
        newConnection.exportedInterface = NSXPCInterface(with: TidyMountHelperProtocol.self)
        newConnection.exportedObject = TidyMountHelper()
        newConnection.resume()
        return true
    }
}

class TidyMountHelper: NSObject, TidyMountHelperProtocol {
    func removeGhostDirectory(at path: String, withReply reply: @escaping (Bool, Error?) -> Void) {
        // Safety checks
        guard path.hasPrefix("/Volumes/") else {
            reply(false, NSError(domain: "TidyMountHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is not in /Volumes"]))
            return
        }
        
        let url = URL(fileURLWithPath: path)
        
        // Ensure the path does not contain '..' to prevent escaping /Volumes
        guard url.standardized.path.hasPrefix("/Volumes/") else {
            reply(false, NSError(domain: "TidyMountHelper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid path"]))
            return
        }
        
        // Only allow rmdir, not rm -rf. rmdir will naturally fail if the directory is not empty.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/rmdir")
        process.arguments = [path]
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                reply(true, nil)
            } else {
                reply(false, NSError(domain: "TidyMountHelper", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "rmdir failed with status \(process.terminationStatus)"]))
            }
        } catch {
            reply(false, error)
        }
    }
}

@main
struct HelperMain {
    static func main() {
        let delegate = TidyMountHelperDelegate()
        let listener = NSXPCListener(machServiceName: "com.tidymount.helper")
        listener.delegate = delegate
        listener.resume()

        // Keep the daemon running
        RunLoop.main.run()
    }
}
