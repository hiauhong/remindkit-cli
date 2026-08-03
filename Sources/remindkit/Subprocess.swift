import EventKitCore
import Foundation

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
    var result: EventKitRaw?
    var fetchError: Error?

    Task {
        do {
            let store = try await RemindersAuth.requestAccess()
            let ekStore = RemindersStore(store: store)
            let raw = await ekStore.fetchAll()
            result = raw
        } catch {
            fetchError = error
        }
        semaphore.signal()
    }

    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
    if let fetchError {
        fail(fetchError)
    }
    return result!
}

// MARK: - ReminderKit Subprocess

/// Run the ReminderKit subprocess in read mode. Pass `includeSections: false`
/// to skip per-reminder section lookups (the slow part — ~4ms × reminders in
/// sectioned lists through remindd) when the caller doesn't need the field.
/// Pass `listsOnly: true` to skip reminder enumeration entirely (structure
/// only — `setup`'s default evaluates lists without reading their contents).
func runReminderKitSubprocess(includeSections: Bool = true, listsOnly: Bool = false) -> ReminderKitRaw? {
    guard let binaryURL = findSubprocessBinary() else {
        fputs("remindkit: warning: ReminderKit subprocess not found, falling back to EventKit\n", stderr)
        return nil
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
    var outputData = Data()
    var errData = Data()
    let doneReading = DispatchSemaphore(value: 0)
    let doneErr = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        doneReading.signal()
    }
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        doneErr.signal()
    }

    do {
        try process.run()
        if !waitForExit(process) {
            fputs("remindkit: warning: ReminderKit subprocess timed out, falling back to EventKit\n", stderr)
            return nil
        }
        doneReading.wait()
        doneErr.wait()

        guard !outputData.isEmpty else {
            // Surface the subprocess stderr only when the run failed — on
            // success it carries nothing but ReminderKit internal logs, which
            // would pollute the caller's stderr for agents.
            emitSubprocessStderr(errData)
            fputs("remindkit: warning: ReminderKit subprocess produced no output, falling back to EventKit\n", stderr)
            return nil
        }

        return try JSONDecoder().decode(ReminderKitRaw.self, from: outputData)
    } catch {
        emitSubprocessStderr(errData)
        fputs("remindkit: warning: ReminderKit subprocess failed, falling back to EventKit: \(error.localizedDescription)\n", stderr)
        return nil
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

/// Run a write request through the ReminderKit subprocess (`write` mode).
/// Returns the parsed result dict, or nil when the subprocess is unavailable
/// (caller should fall back to EventKit). A non-nil result with
/// `ok == false` carries an error message from the subprocess.
func runReminderKitWrite(_ request: [String: Any]) -> [String: Any]? {
    guard let binaryURL = findSubprocessBinary() else {
        fputs("remindkit: warning: ReminderKit subprocess not found, falling back to EventKit\n", stderr)
        return nil
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

    var outputData = Data()
    var errData = Data()
    let doneReading = DispatchSemaphore(value: 0)
    let doneErr = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        doneReading.signal()
    }
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        doneErr.signal()
    }

    do {
        try process.run()
        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        inputPipe.fileHandleForWriting.write(data)
        try inputPipe.fileHandleForWriting.close()
        if !waitForExit(process) {
            fputs("remindkit: warning: ReminderKit subprocess timed out, falling back to EventKit\n", stderr)
            return nil
        }
        doneReading.wait()
        doneErr.wait()

        guard !outputData.isEmpty else {
            emitSubprocessStderr(errData)
            fputs("remindkit: warning: ReminderKit subprocess produced no output, falling back to EventKit\n", stderr)
            return nil
        }
        return try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
    } catch {
        emitSubprocessStderr(errData)
        fputs("remindkit: warning: ReminderKit write subprocess failed, falling back to EventKit: \(error.localizedDescription)\n", stderr)
        return nil
    }
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
