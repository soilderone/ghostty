import Foundation

/// OpenSSH launches the bundled helper for password, key passphrase and host-key prompts.
/// The helper's answer goes straight back to OpenSSH; the terminal app never stores it.
enum SSHAuthentication {
    static func configure(_ config: inout Ghostty.SurfaceConfiguration, for connection: SSHConnection) {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let helper = directory.appendingPathComponent("ghostty-ssh-askpass")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }

        config.environmentVariables["SSH_ASKPASS"] = helper.path
        config.environmentVariables["SSH_ASKPASS_REQUIRE"] = "force"
        config.environmentVariables["GHOSTTY_SSH_DESTINATION"] = connection.displayName
    }
}
