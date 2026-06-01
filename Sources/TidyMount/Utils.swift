import Foundation
import os

enum TimeoutError: Error {
    case timedOut
}

func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }
        
        let result = try await group.next()
        group.cancelAll()
        
        guard let result = result else {
            throw TimeoutError.timedOut
        }
        
        return result
    }
}
