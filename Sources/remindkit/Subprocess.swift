import EventKitCore
import Foundation

// MARK: - Swift 6 strict-concurrency helper

/// Mutable reference box for capturing results out of `@Sendable` closures
/// (`Task` / `DispatchQueue.async`). Safe because every call site waits on a
/// semaphore (or the data is otherwise complete) before reading `.value`.
final class CaptureBox<Value>: @unchecked Sendable {
    var value: Value?
    init() {}
}

// MARK: - Structured errors

/// Emit a machine-readable error object on stderr and exit.
/// Agents should parse stderr; stdout is reserved for data.
/// Refuse write operations when read-only mode is on. Set
/// `REMINDKIT_READ_ONLY=1` (environment or `remindkit --read-only`) to make
/// every write command (add/complete/delete/move/add-list/update-list/
/// delete-list/restore) fail safely instead of mutating reminders.
func guardWriteEnabled() {
    let env = ProcessInfo.processInfo.environment
    let readOnly = env["REMINDKIT_READ_ONLY"]?.lowercased()
    if readOnly == "1" || readOnly == "true" {
        fail("readOnly", "write operations are disabled: REMINDKIT_READ_ONLY is set")
    }
}

/// Pre-flight permission check for write operations: when access is not yet
/// granted, fail with `accessDenied` and point at `remindkit authorize`.
/// Never auto-prompt from a write path — the authorization dialog must be
/// triggered only by the explicit `authorize` command (writes stay
/// side-effect-free), and the default ReminderKit subprocess path never
/// requests access anyway.
func guardRemindersAccess() {
    switch RemindersAuth.checkAccessState() {
    case .granted:
        return
    case .notDetermined:
        fail("accessDenied",
             "Apple Reminders 权限尚未授权（host: \(responsibleProcessName())）。运行 'remindkit authorize' 触发授权弹窗。")
    case .denied:
        fail("accessDenied",
             "Apple Reminders 权限被拒绝（host: \(responsibleProcessName())）。先重置：tccutil reset Reminders，再运行 'remindkit authorize'。")
    case .restricted:
        fail("accessDenied",
             "Apple Reminders 权限受策略限制（如 MDM）。")
    }
}

func fail(_ code: String, _ message: String, exitCode: Int32 = 1) -> Never {
    let payload: [String: Any] = ["error": ["code": code, "message": message]]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    FileHandle.standardError.write(data)
    FileHandle.standardError.write(Data("\n".utf8))
    exit(exitCode)
}

func fail(_ error: Error) -> Never {
    let code: String
    let exitCode: Int32
    let message: String
    if let rkError = error as? RemindKitError {
        code = rkError.code
        exitCode = rkError.exitCode
        message = rkError.errorDescription ?? error.localizedDescription
    } else if let coded = error as? ErrorCoded {
        code = coded.code
        exitCode = coded.exitCode
        message = coded.errorDescription ?? error.localizedDescription
    } else {
        code = "failure"
        exitCode = 1
        message = error.localizedDescription
    }
    fail(code, message, exitCode: exitCode)
}

/// Errors that carry a machine-readable `code` and process `exitCode` for the
/// agent-facing error contract (`{"error": {"code": …, "message": …}}`).
protocol ErrorCoded: LocalizedError {
    var code: String { get }
    var exitCode: Int32 { get }
}

// MARK: - EventKit

func fetchEventKitData() -> EventKitRaw {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = CaptureBox<EventKitRaw>()
    let errorBox = CaptureBox<Error>()

    Task {
        do {
            let store = try await RemindersAuth.requestAccess()
            let ekStore = RemindersStore(store: store)
            let raw = await ekStore.fetchAll()
            resultBox.value = raw
        } catch {
            errorBox.value = error
        }
        semaphore.signal()
    }

    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
    if let fetchError = errorBox.value {
        fail(fetchError)
    }
    return resultBox.value!
}

// MARK: - ReminderKit Subprocess

/// Run the ReminderKit subprocess in read mode. Pass `includeSections: false`
/// to skip per-reminder section lookups (the slow part — ~4ms × reminders in
/// sectioned lists through remindd) when the caller doesn't need the field.
/// Pass `listsOnly: true` to skip reminder enumeration entirely (structure
/// only — `setup`'s default evaluates lists without reading their contents).
enum ReminderKitReadOutcome {
    case success(ReminderKitRaw)
    case unavailable(String)
    case failed(String)
}

func runReminderKitSubprocess(includeSections: Bool = true, listsOnly: Bool = false) -> ReminderKitReadOutcome {
    guard let binaryURL = findSubprocessBinary() else {
        let detail = "ReminderKit subprocess not found"
        fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
        return .unavailable(detail)
    }

    let process = Process()
    process.executableURL = binaryURL
    var args: [String] = []
    if !includeSections { args.append("--no-sections") }
    if listsOnly { args.append("--lists-only") }
    process.arguments = args

    let pipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errPipe

    // 子进程输出较大时 pipe buffer 会满, 必须在 waitUntilExit 之前开始读
    let outputBox = CaptureBox<Data>()
    let errBox = CaptureBox<Data>()
    let doneReading = DispatchSemaphore(value: 0)
    let doneErr = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        outputBox.value = pipe.fileHandleForReading.readDataToEndOfFile()
        doneReading.signal()
    }
    DispatchQueue.global().async {
        errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
        doneErr.signal()
    }

    do {
        try process.run()
    } catch {
        let detail = "ReminderKit subprocess failed to start: \(error.localizedDescription)"
        fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
        return .unavailable(detail)
    }

    let exited = waitForExit(process)
    doneReading.wait()
    doneErr.wait()

    guard exited else {
        emitSubprocessStderr(errBox.value ?? Data())
        let detail = "ReminderKit subprocess timed out"
        fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
        return .failed(detail)
    }

    guard let output = outputBox.value, !output.isEmpty else {
        emitSubprocessStderr(errBox.value ?? Data())
        let detail = "ReminderKit subprocess produced no output"
        fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
        return .failed(detail)
    }

    do {
        let raw = try JSONDecoder().decode(ReminderKitRaw.self, from: output)
        if raw.ok == false {
            let detail = raw.error ?? "ReminderKit read failed"
            emitSubprocessStderr(errBox.value ?? Data())
            fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
            return .failed(detail)
        }
        if process.terminationStatus != 0 {
            let detail = raw.error ?? "ReminderKit subprocess exited with status \(process.terminationStatus)"
            emitSubprocessStderr(errBox.value ?? Data())
            fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
            return .failed(detail)
        }
        if listsOnly ? raw.lists == nil : raw.reminders == nil {
            let detail = listsOnly
                ? "ReminderKit response did not contain lists"
                : "ReminderKit response did not contain reminders"
            fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
            return .failed(detail)
        }
        return .success(raw)
    } catch {
        emitSubprocessStderr(errBox.value ?? Data())
        let detail = "invalid ReminderKit response: \(error.localizedDescription)"
        fputs("remindkit: warning: \(detail), falling back to EventKit\n", stderr)
        return .failed(detail)
    }
}

/// Forward the subprocess's captured stderr (ReminderKit internal logs) to
/// the caller's stderr, trimmed, for diagnosis of failures.
private func emitSubprocessStderr(_ data: Data) {
    guard let text = String(data: data, encoding: .utf8) else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        fputs("remindkit: subprocess stderr: \(trimmed)\n", stderr)
    }
}

/// Wait for a subprocess to exit, with a timeout. If it hangs (e.g. remindd
/// stalled), terminate it and report so the caller can fall back instead of
/// blocking the CLI forever.
@discardableResult
private func waitForExit(_ process: Process, timeout: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        return false
    }
    return true
}

// MARK: - ReminderKit Write (primary write path)

/// Outcome of running a write request through the ReminderKit subprocess.
/// The distinction matters for write safety: a timeout or missing output does
/// NOT prove the write didn't happen — the subprocess may have committed the
/// change and then stalled/crashed. Only `.unavailable` (never started) is
/// safe to fall back to EventKit; `.unknownOutcome` must surface an error so
/// the caller never blindly retries a possibly-committed write.
enum ReminderKitWriteOutcome {
    case success([String: Any])     // parsed result dict from the subprocess
    case unavailable                 // binary missing / failed to start
    case unknownOutcome(String)      // ran but result is unknown (timeout/no output/parse failure)
}

/// Run a write request through the ReminderKit subprocess (`write` mode).
/// See `ReminderKitWriteOutcome` for the tri-state contract.
func runReminderKitWrite(_ request: [String: Any]) -> ReminderKitWriteOutcome {
    guard let binaryURL = findSubprocessBinary() else {
        fputs("remindkit: warning: ReminderKit subprocess not found, falling back to EventKit\n", stderr)
        return .unavailable
    }

    let process = Process()
    process.executableURL = binaryURL
    process.arguments = ["write"]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errPipe

    let outputBox = CaptureBox<Data>()
    let errBox = CaptureBox<Data>()
    let doneReading = DispatchSemaphore(value: 0)
    let doneErr = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        outputBox.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
        doneReading.signal()
    }
    DispatchQueue.global().async {
        errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
        doneErr.signal()
    }

    do {
        try process.run()
    } catch {
        emitSubprocessStderr(errBox.value ?? Data())
        fputs("remindkit: warning: ReminderKit write subprocess failed to start, falling back to EventKit: \(error.localizedDescription)\n", stderr)
        return .unavailable
    }

    do {
        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        inputPipe.fileHandleForWriting.write(data)
        try inputPipe.fileHandleForWriting.close()
    } catch {
        // Process started but stdin broke — it may have consumed a partial
        // request. Result is unknown: do not fall back blindly.
        process.terminate()
        process.waitUntilExit()
        return .unknownOutcome("写入 stdin 失败：\(error.localizedDescription)")
    }

    if !waitForExit(process) {
        // Timed out: the subprocess (or remindd beneath it) stalled. It may
        // have already committed the write — never auto-fallback.
        return .unknownOutcome("子进程超时（可能已写入但未返回结果）")
    }
    doneReading.wait()
    doneErr.wait()

    guard let raw = outputBox.value, !raw.isEmpty else {
        emitSubprocessStderr(errBox.value ?? Data())
        return .unknownOutcome("子进程无输出（已退出，写入结果未知）")
    }
    guard let obj = try? JSONSerialization.jsonObject(with: raw),
          let parsed = obj as? [String: Any] else {
        emitSubprocessStderr(errBox.value ?? Data())
        return .unknownOutcome("子进程输出无法解析（写入结果未知）")
    }
    return .success(parsed)
}

func findSubprocessBinary() -> URL? {
    let binaryName = "fetch-remindkit"

    // 1. Bundle.main.executableURL: kernel-resolved real path of the running
    //    binary. Reliable even when invoked via PATH (argv[0] is the bare
    //    command name) or through a symlink.
    if let execURL = Bundle.main.executableURL {
        let sibling = execURL.deletingLastPathComponent().appendingPathComponent(binaryName)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
    }

    // 2. argv[0] fallback: resolve relative invocation against the cwd.
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let sibling = execURL.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) {
        return sibling
    }

    // 3. Dev fallback: Binaries/ next to the repo checkout.
    let cwd = FileManager.default.currentDirectoryPath
    let devBinary = URL(fileURLWithPath: cwd).appendingPathComponent("Binaries/\(binaryName)")
    if FileManager.default.isExecutableFile(atPath: devBinary.path) {
        return devBinary
    }

    return nil
}
