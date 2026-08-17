import EventKit
import Foundation

public enum RemindersAuth {
    public static func requestAccess() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        guard granted else {
            throw RemindKitError.accessDenied(host: responsibleProcessName())
        }
        return store
    }

    /// Synchronous wrapper for non-async command contexts (ArgumentParser
    /// `run()` is sync). Runs the async request on a Task while pumping the
    /// run loop, mirroring `fetchEventKitData()`.
    public static func requestAccessSync() -> EKEventStore {
        // Swift 6 strict concurrency: capture state in a reference box instead of
        // mutating captured vars from the Task. Safe because the semaphore wait
        // below guarantees the Task finished before we read the box.
        final class Box: @unchecked Sendable {
            var result: EKEventStore?
            var error: Error?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.result = try await requestAccess()
            } catch let caught {
                box.error = caught
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        if let error = box.error {
            let rkError = error as? RemindKitError
            let message = rkError?.errorDescription ?? error.localizedDescription
            let code = rkError?.code ?? "failure"
            let payload: [String: Any] = ["error": ["code": code, "message": message]]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
            exit(rkError?.exitCode ?? 1)
        }
        return box.result!
    }

    /// Non-prompting TCC status check. Safe to call from any context.
    public static func checkAccessState() -> RemindersAccessState {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}

public enum RemindersAccessState: String {
    case granted
    case denied
    case restricted
    case notDetermined
}

/// Best-effort name of the responsible (host) process that launched us.
/// macOS TCC grants belong to this process, not to the CLI binary itself.
public func responsibleProcessName() -> String {
    var path = [CChar](repeating: 0, count: 4096)
    let count = proc_pidpath(getppid(), &path, UInt32(path.count))
    guard count > 0 else { return "unknown" }
    let pathString = String(cString: path)
    return URL(fileURLWithPath: pathString).lastPathComponent
}

public enum RemindKitError: LocalizedError {
    case accessDenied(host: String?)
    case subprocessNotFound

    public var code: String {
        switch self {
        case .accessDenied: return "accessDenied"
        case .subprocessNotFound: return "subprocessNotFound"
        }
    }

    public var exitCode: Int32 { 1 }

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let host):
            let hostSuffix = host.map { " (host: \($0))" } ?? ""
            return "Apple Reminders access denied\(hostSuffix). Run 'remindkit authorize' to trigger the permission prompt. If it was previously denied, reset first: tccutil reset Reminders, then run 'remindkit authorize' again."
        case .subprocessNotFound:
            return "CReminderKit subprocess binary not found"
        }
    }
}
