import ArgumentParser
import EventKitCore
import Foundation

/// Shared authorize logic, used by both the `authorize` command and
/// `doctor --authorize` (second entry point). ArgumentParser command structs
/// must not be nested-constructed directly, so the logic lives in a free
/// function instead.
func runAuthorize(check: Bool, verify: Bool, json: Bool) throws {
    let host = responsibleProcessName()
    let access = RemindersAuth.checkAccessState()

    // --check: never prompt, just report state.
    if check {
        emitAuthorizeState(access: access, host: host, message: nil, verify: nil, json: json)
        return
    }

    switch access {
    case .granted:
        var verifyStatus: String?
        if verify { verifyStatus = verifyPrimaryPath() }
        emitAuthorizeState(access: access, host: host, message: "OK", verify: verifyStatus, json: json)

    case .notDetermined:
        // The only effective path: EventKit requestAccess pops the TCC
        // dialog. Synchronously waits for the user to answer. On denial
        // requestAccessSync already emits the structured error and exits.
        _ = RemindersAuth.requestAccessSync()
        let after = RemindersAuth.checkAccessState()
        var verifyStatus: String?
        if verify, after == .granted { verifyStatus = verifyPrimaryPath() }
        emitAuthorizeState(access: after, host: host,
                           message: after == .granted ? "Authorization granted" : nil,
                           verify: verifyStatus, json: json)

    case .denied:
        // System Settings cannot grant access to a headless host (no GUI
        // entry to check). The user must reset TCC and retry authorize.
        let message = """
            Reminders access is denied (host: \(host)).
            Reset the permission, then run 'remindkit authorize' again:
              tccutil reset Reminders
            (This resets Reminders permission for all apps; re-run 'remindkit authorize' to re-grant for this host.)
            """
        emitAuthorizeState(access: access, host: host, message: message, verify: nil, json: json)

    case .restricted:
        emitAuthorizeState(access: access, host: host,
                           message: "Reminders access is restricted by policy (e.g. MDM).",
                           verify: nil, json: json)
    }
}

/// Verify the primary data path (ReminderKit subprocess) can actually read
/// reminders now that permission is granted — TCC grants belong to the
/// responsible host process, so the subprocess inherits it too.
private func verifyPrimaryPath() -> String {
    switch runReminderKitSubprocess(includeSections: false) {
    case let .success(rk):
        let reminders = rk.reminders ?? []
        return "ok (\(reminders.count) reminders)"
    case let .unavailable(detail), let .failed(detail):
        return "failed (\(detail))"
    }
}

private func emitAuthorizeState(access: RemindersAccessState, host: String,
                                message: String?, verify: String?, json: Bool) {
    if json {
        var payload: [String: Any] = [
            "access": access.rawValue,
            "host": host,
        ]
        if let message { payload["message"] = message }
        if let verify { payload["verify"] = verify }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            print(String(data: data, encoding: .utf8)!)
        }
    } else {
        print("Reminders access: \(access.rawValue) (host: \(host))")
        if let message { print(message) }
        if let verify { print("Verify: \(verify)") }
        if access == .denied {
            print("System Settings cannot grant access for this host — only 'remindkit authorize' (app-triggered) can.")
        }
    }
}

/// `remindkit authorize` — proactively request macOS Reminders permission.
///
/// Why this exists: the default data path (ReminderKit private-framework
/// subprocess) never calls `requestAccess`, so an unauthenticated host
/// silently gets empty data and NO system prompt ever appears. The only path
/// that triggers the TCC authorization dialog is EventKit's
/// `requestFullAccessToReminders()` — reachable via `RemindersAuth.requestAccess()`.
/// This command exposes that path explicitly so a fresh host can be authorized
/// without manually disabling the subprocess binary.
struct Authorize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authorize",
        abstract: "Request macOS Reminders permission (triggers the system authorization prompt)"
    )

    @Flag(name: .long, help: "Non-interactive: print permission state and exit without requesting")
    var check: Bool = false

    @Flag(name: .long, help: "After granting, verify the ReminderKit subprocess can read data")
    var verify: Bool = false

    @Flag(name: .long, help: "Emit machine-readable JSON")
    var json: Bool = false

    func run() throws {
        try runAuthorize(check: check, verify: verify, json: json)
    }
}
