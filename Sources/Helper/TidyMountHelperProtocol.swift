import Foundation

@objc protocol TidyMountHelperProtocol {
    func removeGhostDirectory(at path: String, withReply reply: @escaping (Bool, Error?) -> Void)
}
