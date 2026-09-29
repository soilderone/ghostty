import Foundation

struct SSHOutput {
    let data: Data
    let truncated: Bool

    var text: String { data.lossyUTF8String }
}

struct SSHCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs noninteractive commands over the authenticated OpenSSH connection. A background command
/// never asks for credentials or accepts a new host key: those prompts belong in the terminal.
enum SSHRunner {
    static let maxOutputBytes = 4 * 1024 * 1024
    private static let maxStderrBytes = 16 * 1024

    static func run(
        _ command: String,
        on connection: SSHConnection,
        maxBytes: Int = maxOutputBytes,
        timeout: TimeInterval = 30,
        successCodes: Set<Int32> = [0]
    ) async throws -> SSHOutput {
        guard let controlPath = SSHControlPaths.shared.path(for: connection) else {
            throw SSHCommandError(message: "Cannot create a private SSH control socket.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runBlocking(
                        command,
                        on: connection,
                        controlPath: controlPath,
                        maxBytes: maxBytes,
                        timeout: timeout,
                        successCodes: successCodes)
                })
            }
        }
    }

    private static func runBlocking(
        _ command: String,
        on connection: SSHConnection,
        controlPath: String,
        maxBytes: Int,
        timeout: TimeInterval,
        successCodes: Set<Int32>
    ) throws -> SSHOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
        ] + SSHConnection.controlOptions(path: controlPath) + connection.sshArguments + [command]

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SSHCommandError(message: "Cannot run ssh: \(error.localizedDescription)")
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }

        var errorData = Data()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global().async {
            let reader = stderr.fileHandleForReading
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                if errorData.count < maxStderrBytes {
                    errorData.append(chunk.prefix(maxStderrBytes - errorData.count))
                }
            }
            errorRead.leave()
        }

        var data = Data()
        var truncated = false
        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxBytes {
                data = data.prefix(maxBytes)
                truncated = true
                process.terminate()
                break
            }
        }

        process.waitUntilExit()
        errorRead.wait()

        if truncated { return SSHOutput(data: data, truncated: true) }
        guard successCodes.contains(process.terminationStatus) else {
            let message = errorData.lossyUTF8String.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHCommandError(message: message.isEmpty ? "Remote command failed on \(connection.displayName)." : message)
        }
        return SSHOutput(data: data, truncated: false)
    }
}
