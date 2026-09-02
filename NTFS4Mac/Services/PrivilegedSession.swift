import Foundation

/// Keeps a root helper alive for the app lifetime so the password
/// dialog appears once (on first privileged action), not on every mount.
final class PrivilegedSession: @unchecked Sendable {
    static let shared = PrivilegedSession()

    private let lock = NSLock()
    private var sessionDirectory: URL?
    private var helperProcess: Process?

    func run(_ script: String) throws -> (stdout: String, exitCode: Int32, stderr: String) {
        try ensureHelper()

        let directory = try lockedDirectory()
        let requestURL = directory.appendingPathComponent("request.sh")
        let stdoutURL = directory.appendingPathComponent("response.stdout")
        let stderrURL = directory.appendingPathComponent("response.stderr")
        let exitURL = directory.appendingPathComponent("response.exit")

        for url in [requestURL, stdoutURL, stderrURL, exitURL] {
            try? FileManager.default.removeItem(at: url)
        }

        let content = "#!/bin/sh\n" + script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let staging = directory.appendingPathComponent("request.sh.tmp")
        try content.write(to: staging, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: staging, to: requestURL)

        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: exitURL.path) {
            if Date() > deadline {
                throw PrivilegedSessionError.timeout
            }
            if !isHelperAlive() {
                throw PrivilegedSessionError.helperExited
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let exitText = (try? String(contentsOf: exitURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        let exitCode = Int32(exitText) ?? 1

        for url in [requestURL, stdoutURL, stderrURL, exitURL] {
            try? FileManager.default.removeItem(at: url)
        }

        return (stdout, exitCode, stderr)
    }

    func stop() {
        lock.lock()
        let process = helperProcess
        let directory = sessionDirectory
        helperProcess = nil
        sessionDirectory = nil
        lock.unlock()

        if let directory {
            try? "1".write(
                to: directory.appendingPathComponent("stop"),
                atomically: true,
                encoding: .utf8
            )
        }
        process?.terminate()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func lockedDirectory() throws -> URL {
        lock.lock()
        let directory = sessionDirectory
        lock.unlock()
        guard let directory else { throw PrivilegedSessionError.notStarted }
        return directory
    }

    private func ensureHelper() throws {
        if isHelperAlive() { return }
        stop()
        try startHelper()
    }

    private func isHelperAlive() -> Bool {
        lock.lock()
        let process = helperProcess
        let directory = sessionDirectory
        lock.unlock()

        guard let process, process.isRunning else { return false }
        if let directory {
            let stopFile = directory.appendingPathComponent("stop")
            if FileManager.default.fileExists(atPath: stopFile.path) {
                return false
            }
        }
        return true
    }

    private func startHelper() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfs4mac-session-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let loopURL = directory.appendingPathComponent("loop.sh")
        let readyURL = directory.appendingPathComponent("ready")
        let loop = """
        #!/bin/sh
        DIR='\(directory.path)'
        APP_PID='\(ProcessInfo.processInfo.processIdentifier)'
        /bin/chmod 777 "$DIR" 2>/dev/null || true
        /usr/bin/touch "$DIR/ready"
        /bin/chmod 666 "$DIR/ready" 2>/dev/null || true
        while kill -0 "$APP_PID" 2>/dev/null && [ ! -f "$DIR/stop" ]; do
          if [ -f "$DIR/request.sh" ] && [ ! -f "$DIR/response.exit" ]; then
            /bin/sh "$DIR/request.sh" > "$DIR/response.stdout" 2> "$DIR/response.stderr"
            echo $? > "$DIR/response.exit"
            /bin/chmod 666 "$DIR/response.stdout" "$DIR/response.stderr" "$DIR/response.exit" 2>/dev/null || true
            /bin/rm -f "$DIR/request.sh"
          fi
          sleep 0.05
        done
        """
        try loop.write(to: loopURL, atomically: true, encoding: .utf8)

        let appleScriptURL = directory.appendingPathComponent("start.applescript")
        let appleScript = """
        do shell script "/bin/sh " & quoted form of "\(loopURL.path)" with administrator privileges
        """
        try appleScript.write(to: appleScriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [appleScriptURL.path]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: readyURL.path) {
            if Date() > deadline {
                process.terminate()
                try? FileManager.default.removeItem(at: directory)
                throw PrivilegedSessionError.startFailed("Timed out waiting for administrator session")
            }
            if !process.isRunning {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                try? FileManager.default.removeItem(at: directory)
                if stderr.localizedCaseInsensitiveContains("canceled")
                    || stderr.contains("-128") {
                    throw PrivilegedSessionError.canceled
                }
                throw PrivilegedSessionError.startFailed(
                    stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Helper did not start"
                        : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        lock.lock()
        sessionDirectory = directory
        helperProcess = process
        lock.unlock()
    }
}

enum PrivilegedSessionError: LocalizedError {
    case notStarted
    case startFailed(String)
    case canceled
    case helperExited
    case timeout

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "Administrator session is not available."
        case .startFailed(let details):
            return details.isEmpty
                ? "Could not start administrator session."
                : "Could not start administrator session.\n\(details)"
        case .canceled:
            return "Administrator password was canceled."
        case .helperExited:
            return "Administrator session ended. Try the action again."
        case .timeout:
            return "The privileged command timed out."
        }
    }
}
