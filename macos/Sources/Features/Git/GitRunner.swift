import Foundation

/// An error from running git, with the message git printed when it has one.
struct GitError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }

    static let notFound = GitError(message: "git was not found. Install it with the Xcode command line tools or Homebrew.")
    static let notARepository = GitError(message: "Not a git repository.")
}

/// The output of one git command.
struct GitOutput {
    let data: Data

    /// Whether the output reached the size limit and was cut off there.
    let truncated: Bool

    var text: String {
        data.lossyUTF8String
    }

    /// Whether git printed exactly the same. A byte comparison is far cheaper than parsing.
    func isSame(as other: GitOutput) -> Bool {
        truncated == other.truncated && data == other.data
    }
}

/// Runs git commands for the Git view. Everything is read-only: the view never changes the
/// repository, the index or the working tree.
enum GitRunner {
    /// The most output any one command may produce before it is cut off.
    static let maxOutputBytes = 4 * 1024 * 1024

    private static let timeout: TimeInterval = 30
    private static let maxStderrBytes = 16 * 1024
    private static let remoteMarker = Data([0x1e] + Array("GHOSTTY_GIT".utf8) + [0x1f])

    /// The git to run. An app launched from the Finder gets launchd's minimal PATH, where `git`
    /// is the /usr/bin shim that asks to install the command line tools when they're missing,
    /// so a Homebrew git is preferred when there is one.
    static let executable: String? = {
        let fileManager = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fromPath = path.split(separator: ":").map { "\($0)/git" }
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"] +
            fromPath.filter { $0 != "/usr/bin/git" } +
            ["/usr/bin/git"]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }()

    /// Runs git in a directory.
    ///
    /// - Parameters:
    ///   - successCodes: Exit codes that count as success. `git diff --no-index` exits
    ///     with 1 when the files differ.
    static func run(
        _ arguments: [String],
        in directory: String,
        connection: SSHConnection? = nil,
        maxBytes: Int = maxOutputBytes,
        successCodes: Set<Int32> = [0]
    ) async throws -> GitOutput {
        if let connection {
            let options = [
                "-c", "core.quotepath=off",
                "-c", "color.ui=false",
                "-c", "log.showsignature=false",
            ] + arguments
            let command = "cd \(SSHConnection.shellQuote(directory)) && " +
                "printf '\\036GHOSTTY_GIT\\037' && " +
                "LC_ALL=C GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat " +
                "exec git " + options.map(SSHConnection.shellQuote).joined(separator: " ")
            do {
                let output = try await SSHRunner.run(
                    command, on: connection, maxBytes: maxBytes + 4096, successCodes: successCodes)
                guard let range = output.data.range(of: remoteMarker) else {
                    throw GitError(message: "Remote git returned unexpected output.")
                }
                let data = Data(output.data[range.upperBound...].prefix(maxBytes))
                return GitOutput(
                    data: data,
                    truncated: output.truncated || output.data.count - range.upperBound > maxBytes)
            } catch let error as SSHCommandError {
                if error.message.contains("not a git repository") { throw GitError.notARepository }
                throw GitError(message: error.message)
            }
        }
        guard let executable else { throw GitError.notFound }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runBlocking(
                        executable: executable,
                        arguments: arguments,
                        directory: directory,
                        maxBytes: maxBytes,
                        successCodes: successCodes)
                })
            }
        }
    }

    /// Runs git and waits for it. Call this from a background thread.
    static func runBlocking(
        executable: String,
        arguments: [String],
        directory: String,
        maxBytes: Int,
        successCodes: Set<Int32>
    ) throws -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)

        // Quoted paths, colors and signature checks would all get in the way of parsing.
        process.arguments = [
            "-c", "core.quotepath=off",
            "-c", "color.ui=false",
            "-c", "log.showsignature=false",
        ] + arguments

        // English messages so errors can be recognized, no index lock contention with the
        // user's own git commands, and never a prompt or pager.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitError(message: "Cannot run git: \(error.localizedDescription)")
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }

        // Read stderr alongside stdout, or a chatty stderr could fill its pipe and stall git
        // before it closes stdout.
        var errorData = Data()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile().prefix(maxStderrBytes)
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

        if truncated {
            return GitOutput(data: data, truncated: true)
        }

        guard successCodes.contains(process.terminationStatus) else {
            let message = errorData.lossyUTF8String
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("not a git repository") {
                throw GitError.notARepository
            }
            let command = arguments.first ?? ""
            throw GitError(message: message.isEmpty ? "git \(command) failed." : message)
        }

        return GitOutput(data: data, truncated: false)
    }
}
