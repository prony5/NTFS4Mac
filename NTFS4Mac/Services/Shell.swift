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

    /// Runs a shell script as root. Password is asked once per app launch.
    static func runShellScriptWithSudoDetailed(_ script: String) async throws -> (stdout: String, exitCode: Int32, stderr: String) {
        try await Task.detached {
            try PrivilegedSession.shared.run(script)
        }.value
    }

    static func runShellScriptWithSudo(_ script: String) async throws -> (stdout: String, exitCode: Int32) {
        let (stdout, exitCode, _) = try await runShellScriptWithSudoDetailed(script)
        return (stdout, exitCode)
    }

    static func runWithSudoDetailed(_ command: String, arguments: [String] = []) async throws -> (stdout: String, exitCode: Int32, stderr: String) {
        var parts = [command]
        for arg in arguments {
            let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
            parts.append("'\(escaped)'")
        }
        return try await Task.detached {
            try PrivilegedSession.shared.run(parts.joined(separator: " "))
        }.value
    }

    static func runDiskutil(_ arguments: [String]) async throws -> String {
        try await run("/usr/sbin/diskutil", arguments: arguments)
    }
}
