import Foundation

// MARK: - Shell Command Execution

enum Shell {
    static func run(_ command: String, arguments: [String] = []) async throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func runWithSudo(_ command: String, arguments: [String] = []) async throws -> (stdout: String, exitCode: Int32) {
        let (stdout, exitCode, _) = try await runWithSudoDetailed(command, arguments: arguments)
        return (stdout, exitCode)
    }

    /// Runs a shell script with administrator privileges via a temp file to avoid AppleScript quoting issues.
    static func runShellScriptWithSudoDetailed(_ script: String) async throws -> (stdout: String, exitCode: Int32, stderr: String) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfs4mac-\(UUID().uuidString).sh")
        let content = "#!/bin/sh\n" + script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        return try await runWithSudoDetailed("/bin/sh", arguments: [tempURL.path])
    }

    static func runShellScriptWithSudo(_ script: String) async throws -> (stdout: String, exitCode: Int32) {
        let (stdout, exitCode, _) = try await runShellScriptWithSudoDetailed(script)
        return (stdout, exitCode)
    }

    static func runWithSudoDetailed(_ command: String, arguments: [String] = []) async throws -> (stdout: String, exitCode: Int32, stderr: String) {
        var parts = [command]
        for arg in arguments {
            if arg.contains(" ") || arg.contains("'") || arg.contains("\"") || arg.contains("$") {
                let escaped = arg
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                parts.append("\"\(escaped)\"")
            } else {
                parts.append(arg)
            }
        }
        let fullCommand = parts.joined(separator: " ")
        let escapedForAppleScript = fullCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout, process.terminationStatus, stderr)
    }

    static func runDiskutil(_ arguments: [String]) async throws -> String {
        try await run("/usr/sbin/diskutil", arguments: arguments)
    }
}
