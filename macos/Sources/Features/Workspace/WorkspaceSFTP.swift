import Foundation
import Darwin

/// The small SFTP v3 subset used by Files. SSH authentication stays in OpenSSH.
struct SFTPPacket {
    var data = Data()
    var offset = 0

    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func uint64(_ value: UInt64) {
        uint32(UInt32(truncatingIfNeeded: value >> 32))
        uint32(UInt32(truncatingIfNeeded: value))
    }
    mutating func bytes(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw WorkspaceError.message("Truncated SFTP packet.") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func readByte() throws -> UInt8 { try take(1)[0] }
    mutating func readUInt32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func readUInt64() throws -> UInt64 {
        let high = try readUInt32()
        return try (UInt64(high) << 32) | UInt64(readUInt32())
    }
    mutating func readBytes() throws -> Data { try take(Int(readUInt32())) }
    mutating func readString() throws -> String {
        guard let value = String(data: try readBytes(), encoding: .utf8) else {
            throw WorkspaceError.message("This filename is not UTF-8 and cannot be displayed.")
        }
        return value
    }
}

struct SFTPStatus: LocalizedError {
    let code: UInt32
    let message: String
    var errorDescription: String? { "SFTP: \(message) (\(code))" }
}

struct SFTPAttributes {
    var size: UInt64 = 0
    var permissions: UInt32 = 0

    init(_ packet: inout SFTPPacket) throws {
        let flags = try packet.readUInt32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw WorkspaceError.message("Unsupported SFTP attributes.") }
        if flags & 1 != 0 { size = try packet.readUInt64() }
        if flags & 2 != 0 { _ = try packet.take(8) }
        if flags & 4 != 0 { permissions = try packet.readUInt32() }
        if flags & 8 != 0 { _ = try packet.take(8) }
        if flags & 0x80000000 != 0 {
            let count = try packet.readUInt32()
            guard count <= 1024 else { throw WorkspaceError.message("Too many SFTP attributes.") }
            for _ in 0..<count {
                _ = try packet.readBytes()
                _ = try packet.readBytes()
            }
        }
    }
    var regular: Bool { permissions & 0o170000 == 0o100000 }
    var directory: Bool { permissions & 0o170000 == 0o040000 }
    var symbolicLink: Bool { permissions & 0o170000 == 0o120000 }
}

actor RemoteWorkspaceFiles: WorkspaceFileService {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var requestID: UInt32 = 0
    private var connected = false
    private var atomicRename = false
    private var cleaningUp = false
    private let socket: String
    private let destination: String
    private let subsystemExecutable: URL?

    init(socket: String, destination: String) {
        self.socket = socket
        self.destination = destination
        self.subsystemExecutable = nil
    }

    /// Runs the real OpenSSH subsystem directly in integration tests, without
    /// needing credentials or enabling Remote Login on the test machine.
    init(subsystemExecutable: URL) {
        self.socket = ""
        self.destination = ""
        self.subsystemExecutable = subsystemExecutable
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func disconnect() {
        connected = false
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    private func start() throws {
        if connected { return }
        guard process.processIdentifier == 0 else { throw WorkspaceError.message("Connection lost. Reconnect from SSH.") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // With no fallback credentials/network destination, loss of the master cannot
        // silently establish a second connection or prompt on the protocol stream.
        process.arguments = ["-F", "/dev/null", "-S", socket, "-o", "BatchMode=yes",
                             "-o", "ProxyCommand=/usr/bin/false", "-T", "-s", "--", destination, "sftp"]
        if let subsystemExecutable {
            process.executableURL = subsystemExecutable
            process.arguments = []
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let descriptor = input.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            disconnect()
            throw WorkspaceError.message("Cannot configure the SFTP transport.")
        }
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        var packet = SFTPPacket()
        packet.byte(1)
        packet.uint32(3)
        try send(packet)
        var response = try receive()
        guard try response.readByte() == 2, try response.readUInt32() == 3 else {
            disconnect()
            throw WorkspaceError.message("The server does not support SFTP version 3.")
        }
        while response.offset < response.data.count {
            let name = try response.readString()
            let value = try response.readString()
            if name == "posix-rename@openssh.com", value == "1" { atomicRename = true }
        }
        connected = true
    }

    private func send(_ packet: SFTPPacket) throws {
        var framed = SFTPPacket()
        framed.uint32(UInt32(packet.data.count))
        framed.data.append(packet.data)
        let descriptor = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < framed.data.count {
            var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&state, 1, 15_000)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw WorkspaceError.message("SFTP write timed out.") }
            let written = framed.data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), framed.data.count - offset)
            }
            if written < 0, errno == EINTR || errno == EAGAIN { continue }
            guard written > 0 else { throw WorkspaceError.message("SFTP transport closed while writing.") }
            offset += written
        }
    }

    private func exact(_ count: Int) throws -> Data {
        var result = Data()
        let descriptor = output.fileHandleForReading.fileDescriptor
        while result.count < count {
            // Drain an in-flight packet even after cancellation, keeping framing valid.
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&state, 1, 15_000)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else {
                disconnect()
                throw WorkspaceError.message("SFTP timed out. Reconnect to try again.")
            }
            let chunk = try output.fileHandleForReading.read(upToCount: count - result.count) ?? Data()
            guard !chunk.isEmpty else {
                disconnect()
                throw WorkspaceError.message("SFTP disconnected or is unavailable on this server.")
            }
            result.append(chunk)
        }
        return result
    }

    private func receive() throws -> SFTPPacket {
        var header = SFTPPacket(data: try exact(4))
        let count = try header.readUInt32()
        guard count > 0, count <= 1024 * 1024 else {
            disconnect()
            throw WorkspaceError.message("Invalid SFTP packet size.")
        }
        return SFTPPacket(data: try exact(Int(count)))
    }

    private func request(_ type: UInt8, _ body: (inout SFTPPacket) -> Void) throws -> (UInt8, SFTPPacket) {
        if !cleaningUp { try Task.checkCancellation() }
        try start()
        requestID &+= 1
        var packet = SFTPPacket()
        packet.byte(type)
        packet.uint32(requestID)
        body(&packet)
        do {
            try send(packet)
            var response = try receive()
            let kind = try response.readByte()
            guard try response.readUInt32() == requestID else {
                throw WorkspaceError.message("SFTP response does not match its request.")
            }
            if kind == 101 {
                let code = try response.readUInt32()
                let message = try response.readString()
                if code != 0 { throw SFTPStatus(code: code, message: message) }
            }
            return (kind, response)
        } catch let status as SFTPStatus {
            throw status
        } catch {
            disconnect()
            throw error
        }
    }

    private func response(_ type: UInt8, expecting: UInt8, _ body: (inout SFTPPacket) -> Void) throws -> SFTPPacket {
        let (kind, packet) = try request(type, body)
        guard kind == expecting else { throw WorkspaceError.message("Unexpected SFTP response.") }
        return packet
    }

    func resolve(_ path: String) throws -> String {
        var reply = try response(16, expecting: 104) { $0.string(path) }
        guard try reply.readUInt32() == 1 else { throw WorkspaceError.message("Cannot resolve remote path.") }
        return try reply.readString()
    }

    private func attributes(_ path: String, follow: Bool = true) throws -> SFTPAttributes {
        var reply = try response(follow ? 17 : 7, expecting: 105) { $0.string(path) }
        return try SFTPAttributes(&reply)
    }

    private func exists(_ path: String) throws -> Bool {
        do {
            _ = try attributes(path, follow: false)
            return true
        } catch let error as SFTPStatus where error.code == 2 {
            return false
        }
    }

    private func close(_ handle: Data) {
        cleaningUp = true
        defer { cleaningUp = false }
        _ = try? response(4, expecting: 101) { $0.bytes(handle) }
    }

    private func unlinkTemporary(_ path: String) {
        cleaningUp = true
        defer { cleaningUp = false }
        _ = try? response(13, expecting: 101) { $0.string(path) }
    }

    func list(_ path: String) throws -> [WorkspaceFile] {
        var reply = try response(11, expecting: 102) { $0.string(path) }
        let handle = try reply.readBytes()
        defer { close(handle) }
        var files: [WorkspaceFile] = []
        while true {
            do { reply = try response(12, expecting: 104) { $0.bytes(handle) } } catch let error as SFTPStatus where error.code == 1 {
                return files
            }
            let count = try reply.readUInt32()
            guard count <= 16384 else { throw WorkspaceError.message("Invalid directory response.") }
            for _ in 0..<count {
                let name = try reply.readString()
                _ = try reply.readString() // v3 longname is display text, never parsed.
                let attrs = try SFTPAttributes(&reply)
                if name == "." || name == ".." { continue }
                let fullPath = try WorkspacePath.child(name, in: path)
                let directory = attrs.symbolicLink ? ((try? attributes(fullPath).directory) ?? false) : attrs.directory
                files.append(WorkspaceFile(path: fullPath, name: name, directory: directory,
                                           symbolicLink: attrs.symbolicLink, size: attrs.size))
            }
        }
    }

    private func open(_ path: String, flags: UInt32, permissions: UInt32 = 0o600) throws -> Data {
        var reply = try response(3, expecting: 102) {
            $0.string(path)
            $0.uint32(flags)
            $0.uint32(4)
            $0.uint32(permissions & 0o777)
        }
        return try reply.readBytes()
    }

    private func chunk(_ handle: Data, offset: UInt64) throws -> Data {
        do {
            var reply = try response(5, expecting: 103) {
                $0.bytes(handle)
                $0.uint64(offset)
                $0.uint32(32768)
            }
            let data = try reply.readBytes()
            guard !data.isEmpty, data.count <= 32768 else { throw WorkspaceError.message("Invalid SFTP read size.") }
            return data
        } catch let error as SFTPStatus where error.code == 1 { return Data() }
    }

    func read(_ path: String) throws -> Data {
        let attrs = try attributes(path)
        guard attrs.regular else { throw WorkspaceError.message("Only regular files can be opened in the editor.") }
        guard attrs.size <= UInt64(WorkspacePath.textLimit) else {
            throw WorkspaceError.message("The editor supports files up to 5 MiB. Use Download instead.")
        }
        let handle = try open(path, flags: 1)
        defer { close(handle) }
        var data = Data()
        while true {
            let part = try chunk(handle, offset: UInt64(data.count))
            if part.isEmpty { break }
            data.append(part)
            guard data.count <= WorkspacePath.textLimit else { throw WorkspaceError.message("File grew beyond 5 MiB.") }
        }
        _ = try WorkspacePath.text(data)
        return data
    }

    private func write(_ data: Data, handle: Data, offset: UInt64) throws {
        _ = try response(6, expecting: 101) {
            $0.bytes(handle)
            $0.uint64(offset)
            $0.bytes(data)
        }
    }

    private func temporary(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".ghostty-\(UUID().uuidString)")
    }

    func save(_ path: String, data: Data, original: Data?, overwrite: Bool) throws {
        let present = try exists(path)
        let target = present ? try resolve(path) : path
        if !overwrite {
            if let original {
                guard try read(target) == original else { throw WorkspaceError.conflict }
            } else if present { throw WorkspaceError.conflict }
        }
        try start()
        guard !present || atomicRename else {
            throw WorkspaceError.message("This server cannot safely replace files. Save a copy with a new name.")
        }
        let permissions = present ? try attributes(target).permissions : 0o600
        let temp = temporary(target)
        let handle = try open(temp, flags: 2 | 8 | 32, permissions: permissions)
        var handleClosed = false
        defer {
            if !handleClosed { close(handle) }
            unlinkTemporary(temp)
        }
        for offset in stride(from: 0, to: data.count, by: 32768) {
            try write(data.subdata(in: offset..<min(offset + 32768, data.count)), handle: handle, offset: UInt64(offset))
        }
        // Explicit SETSTAT preserves mode despite the remote umask.
        _ = try response(10, expecting: 101) {
            $0.bytes(handle)
            $0.uint32(4)
            $0.uint32(permissions & 0o777)
        }
        _ = try response(4, expecting: 101) { $0.bytes(handle) }
        handleClosed = true
        if !overwrite, let original {
            guard try read(target) == original else { throw WorkspaceError.conflict }
        }
        if present {
            _ = try response(200, expecting: 101) {
                $0.string("posix-rename@openssh.com")
                $0.string(temp)
                $0.string(target)
            }
        } else {
            try rename(temp, to: target)
        }
    }

    func create(_ path: String, directory: Bool) throws {
        if directory {
            _ = try response(14, expecting: 101) {
                $0.string(path)
                $0.uint32(4)
                $0.uint32(0o755)
            }
        } else {
            let handle = try open(path, flags: 2 | 8 | 32)
            _ = try response(4, expecting: 101) { $0.bytes(handle) }
        }
    }

    func rename(_ path: String, to destination: String) throws {
        guard try !exists(destination) else { throw WorkspaceError.conflict }
        _ = try response(18, expecting: 101) {
            $0.string(path)
            $0.string(destination)
        }
    }

    func remove(_ path: String, directory: Bool) throws {
        // SFTP RMDIR only removes empty directories. REMOVE unlinks symlinks.
        let attrs = try attributes(path, follow: false)
        _ = try response(attrs.directory ? 15 : 13, expecting: 101) { $0.string(path) }
    }

    func download(_ path: String, to url: URL, progress: @Sendable @escaping (Double) -> Void) throws {
        let attrs = try attributes(path)
        guard attrs.regular else { throw WorkspaceError.message("Only regular files can be downloaded.") }
        let size = attrs.size
        let handle = try open(path, flags: 1)
        defer { close(handle) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".ghostty-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError.message("Cannot create download file.")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var offset: UInt64 = 0
        while true {
            let part = try chunk(handle, offset: offset)
            if part.isEmpty { break }
            try output.write(contentsOf: part)
            offset += UInt64(part.count)
            progress(min(1, Double(offset) / Double(max(1, size))))
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temp, to: url)
        progress(1)
    }

    func upload(_ url: URL, to path: String, progress: @Sendable @escaping (Double) -> Void) throws {
        guard try !exists(path) else { throw WorkspaceError.conflict }
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceError.message("Only regular files can be uploaded.") }
        let size = values.fileSize ?? 0
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let temp = temporary(path)
        let handle = try open(temp, flags: 2 | 8 | 32)
        var handleClosed = false
        defer {
            if !handleClosed { close(handle) }
            unlinkTemporary(temp)
        }
        var offset: UInt64 = 0
        while let data = try input.read(upToCount: 32768), !data.isEmpty {
            try write(data, handle: handle, offset: offset)
            offset += UInt64(data.count)
            progress(min(1, Double(offset) / Double(max(1, size))))
        }
        _ = try response(4, expecting: 101) { $0.bytes(handle) }
        handleClosed = true
        try rename(temp, to: path)
        progress(1)
    }
}
