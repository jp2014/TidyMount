import Foundation

struct NetworkShare: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: String // e.g., smb://server.local/share
    var displayName: String
    var autoMount: Bool = true
    
    var shareName: String {
        guard let url = URL(string: url) else { return displayName }
        return url.lastPathComponent
    }
}
