import Foundation

actor DatabaseTestMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

enum DatabaseTestLock {
    private static let mutex = DatabaseTestMutex()

    static func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await mutex.acquire()
        do {
            let result = try await operation()
            await mutex.release()
            return result
        } catch {
            await mutex.release()
            throw error
        }
    }
}
