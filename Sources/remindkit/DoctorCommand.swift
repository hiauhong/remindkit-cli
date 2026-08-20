import ArgumentParser
import EventKitCore
import Foundation

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose Reminders permission and setup"
    )

    @Flag(name: .long, help: "Emit machine-readable JSON")
    var json: Bool = false

    @Flag(name: .long, help: "Report from the agent host context")
    var forAgent: Bool = false

    @Flag(name: .long, help: "Request Reminders permission now (triggers the system authorization prompt)")
    var authorize: Bool = false

    func run() throws {
        // doctor --authorize: delegate to the shared authorize logic
        // (second entry point alongside the standalone `authorize` command).
        if authorize {
            try runAuthorize(check: false, verify: false, json: json)
            return
        }

        let access = RemindersAuth.checkAccessState()
        let host = responsibleProcessName()
        let binary = CommandLine.arguments[0]
        let subprocess = findSubprocessBinary() != nil

        // Probe the actual data path: does the subprocess yield reminders?
        var subprocessStatus = "missing"
        if subprocess {
            switch runReminderKitSubprocess(includeSections: false) {
            case let .success(rk):
                subprocessStatus = "ok (\(rk.reminders?.count ?? 0) reminders)"
            case let .unavailable(detail), let .failed(detail):
                subprocessStatus = "failed (\(detail))"
            }
        }
        let primary = subprocessStatus.hasPrefix("ok") ? "reminderKit" : "eventKit (fallback)"
        let fix = fixMessage(for: access, host: host)

        if json {
            let payload: [String: Any] = [
                "access": access.rawValue,
                "host": host,
                "binary": binary,
                "subprocess": subprocessStatus,
                "primary": primary,
                "forAgent": forAgent,
                "fix": fix,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else {
            print("Reminders access: \(access.rawValue) (host: \(host))")
            print("Binary: \(binary)")
            print("ReminderKit subprocess: \(subprocessStatus)")
            print("Primary source: \(primary) (EventKit is the fallback)")
            print("Fix: \(fix)")
        }
    }

    private func fixMessage(for access: RemindersAccessState, host: String) -> String {
        switch access {
        case .granted:
            return "OK"
        case .notDetermined:
            return "Run 'remindkit authorize' (or 'doctor --authorize') to trigger the macOS permission prompt. The default data path (ReminderKit subprocess) never requests access, so running any read command will NOT prompt."
        case .denied:
            return "Reminders access denied for '\(host)'. Reset TCC and retry: tccutil reset Reminders && remindkit authorize (System Settings cannot grant access to a headless host)."
        case .restricted:
            return "Reminders access is restricted by policy (e.g. MDM)."
        }
    }
}
