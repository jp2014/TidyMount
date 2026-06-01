import SwiftUI
import OSLog

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: OSLogEntryLog.Level
}

@MainActor
class LogFetcher: ObservableObject {
    @Published var entries: [LogEntry] = []
    @Published var isFetching = false
    
    func fetchLogs() {
        isFetching = true
        Task {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(timeIntervalSinceLatestBoot: -3600) // Last 1 hour
                let entries = try store.getEntries(at: position)
                    .compactMap { $0 as? OSLogEntryLog }
                    .filter { $0.subsystem == "com.tidymount" }
                    .map { LogEntry(timestamp: $0.date, message: $0.composedMessage, level: $0.level) }
                    .reversed() // Newest first
                
                self.entries = Array(entries)
            } catch {
                print("Failed to fetch logs: \(error)")
            }
            isFetching = false
        }
    }
}

struct LogView: View {
    @StateObject private var fetcher = LogFetcher()
    
    var body: some View {
        VStack {
            HStack {
                Text("App Logs (Last Hour)")
                    .font(.headline)
                Spacer()
                Button(action: { fetcher.fetchLogs() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(fetcher.isFetching)
            }
            .padding()
            
            if fetcher.isFetching && fetcher.entries.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                List(fetcher.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            levelBadge(for: entry.level)
                        }
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            fetcher.fetchLogs()
        }
    }
    
    @ViewBuilder
    private func levelBadge(for level: OSLogEntryLog.Level) -> some View {
        let color: Color = {
            switch level {
            case .error, .fault: return .red
            case .info: return .blue
            case .debug: return .gray
            default: return .secondary
            }
        }()
        
        Text(levelName(for: level))
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
    
    private func levelName(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        default: return "DEFAULT"
        }
    }
}
