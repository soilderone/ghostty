import Foundation
import Testing
@testable import Ghostty

@Suite
struct SSHConnectionTests {
    @Test func parsesWaveDestinations() throws {
        let alias = try SSHConnection.parse("build-server")
        #expect(alias.host == "build-server")
        #expect(alias.user == nil)
        #expect(alias.port == nil)

        let destination = try SSHConnection.parse("alice@example.com:2222")
        #expect(destination.destination == "alice@example.com")
        #expect(destination.port == 2222)
        #expect(destination.displayName == "alice@example.com:2222")

        let ipv6 = try SSHConnection.parse("alice@[2001:db8::1]:2200")
        #expect(ipv6.displayName == "alice@[2001:db8::1]:2200")
    }

    @Test func rejectsOptionsAndInvalidPorts() {
        #expect(throws: SSHConnectionError.self) { try SSHConnection.parse("-oProxyCommand=bad") }
        #expect(throws: SSHConnectionError.self) { try SSHConnection.parse("host:0") }
        #expect(throws: SSHConnectionError.self) { try SSHConnection.parse("host:65536") }
        #expect(throws: SSHConnectionError.self) { try SSHConnection.parse("host\nother") }
    }

    @Test func quotesShellArgumentsAndRevalidatesRestoredHosts() throws {
        #expect(SSHConnection.shellQuote("a'b") == "'a'\\''b'")
        let connection = try SSHConnection.parse("alice@example.com:2222")
        let restored = try JSONDecoder().decode(SSHConnection.self, from: JSONEncoder().encode(connection))
        #expect(restored == connection)
        #expect(throws: SSHConnectionError.self) {
            try JSONDecoder().decode(SSHConnection.self, from: Data("\"-oProxyCommand=bad\"".utf8))
        }
    }

    @Test func terminalCommandDoesNotDoubleExec() throws {
        let connection = try SSHConnection.parse("alice@example.com:2222")
        let command = connection.terminalCommand(controlPath: "/tmp/ghostty ssh socket")
        let executable = Bundle.main.executableURL?.path ?? "/usr/bin/ssh"
        #expect(command.hasPrefix(SSHConnection.shellQuote(executable) + " "))
        #expect(!command.hasPrefix("exec "))
        #expect(command.contains("'-p' '2222' 'alice@example.com'"))
        #expect(command.contains("'ControlPath=/tmp/ghostty ssh socket'"))
    }

    @Test func resolvesRemotePathsWithoutLocalHomeExpansion() {
        #expect(SSHRemotePath.resolve("~/src", current: "/work", home: "/home/alice") == "/home/alice/src")
        #expect(SSHRemotePath.resolve("../repo", current: "/home/alice/src", home: "/home/alice") == "/home/alice/repo")
        #expect(SSHRemotePath.resolve("~", current: "/work", home: nil) == nil)
    }
}
