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

    func run() throws {
        let access = RemindersAuth.checkAccessState()
        let host = responsibleProcessName()
        let binary = CommandLine.arguments[0]
        let subprocess = findSubprocessBinary() != nil

        // Probe the actual data path: does the subprocess yield reminders?
        var subprocessStatus = "missing"
        if subprocess {
            if let rk = runReminderKitSubprocess(includeSections: false), rk.reminders != nil {
                subprocessStatus = "ok (\(rk.reminders?.count ?? 0) reminders)"
            } else {
                subprocessStatus = "failed"
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
            return "Run any command once from this host (\(host)) and approve the Reminders prompt, or grant access in System Settings > Privacy & Security > Reminders."
        case .denied:
            return "Grant Reminders access to '\(host)' in System Settings > Privacy & Security > Reminders. Open: open x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .restricted:
            return "Reminders access is restricted by policy (e.g. MDM)."
        }
    }
}
