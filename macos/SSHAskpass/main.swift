import AppKit
import Darwin
import SwiftUI

private enum PromptKind {
    case hostKey
    case confirmation
    case secret
    case notice

    init(message: String, hint: String?) {
        let lowercased = message.lowercased()
        if hint == "none" {
            self = .notice
        } else if lowercased.contains("yes/no") || lowercased.contains("please type 'yes'") {
            self = .hostKey
        } else if hint == "confirm" {
            self = .confirmation
        } else {
            self = .secret
        }
    }

    var title: String {
        switch self {
        case .hostKey: "Verify SSH host key"
        case .confirmation: "Confirm SSH request"
        case .secret: "SSH authentication"
        case .notice: "SSH verification"
        }
    }

    var symbol: String {
        switch self {
        case .hostKey: "checkmark.shield"
        case .confirmation: "checkmark.shield"
        case .secret: "lock.shield"
        case .notice: "key.horizontal"
        }
    }

    var needsAnswer: Bool {
        self != .notice
    }

    var isConfirmation: Bool {
        self == .hostKey || self == .confirmation
    }
}

private final class PromptSession: NSObject, NSWindowDelegate {
    let message: String
    let destination: String?
    let kind: PromptKind
    private var finished = false

    init(message: String, destination: String?, hint: String?) {
        self.message = message
        self.destination = destination
        kind = PromptKind(message: message, hint: hint)
    }

    func answer(_ value: String?) {
        guard !finished else { return }
        finished = true
        guard let value else { Darwin.exit(1) }
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
        Darwin.exit(0)
    }

    func windowWillClose(_ notification: Notification) {
        answer(nil)
    }
}

private struct PromptView: View {
    let session: PromptSession

    @State private var answer = ""
    @FocusState private var answerFocused: Bool

    private let background = Color(red: 0.10, green: 0.13, blue: 0.11)
    private let raised = Color(red: 0.15, green: 0.19, blue: 0.16)
    private let accent = Color(red: 0.61, green: 0.77, blue: 0.53)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: session.kind.symbol)
                    .font(.system(size: 19))
                    .foregroundColor(accent)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.kind.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let destination = session.destination {
                        Text(destination)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            ScrollView {
                Text(session.message)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: session.kind == .hostKey ? 134 : 78)

            if session.kind == .hostKey {
                Text("Check the fingerprint with your server before trusting this host.")
                    .font(.system(size: 11))
                    .foregroundColor(accent)
            } else if session.kind == .secret {
                SecureField("Password or key passphrase", text: $answer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .focused($answerFocused)
                    .onSubmit { session.answer(answer) }
            }

            HStack {
                Spacer()
                Button("Cancel") { session.answer(nil) }
                    .keyboardShortcut(.cancelAction)
                if session.kind.needsAnswer {
                    Button(session.kind == .hostKey ? "Trust Host" :
                           (session.kind == .confirmation ? "Confirm" : "Continue")) {
                        session.answer(session.kind.isConfirmation ? "yes" : answer)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .buttonStyle(.bordered)
        }
        .foregroundColor(Color(red: 0.89, green: 0.91, blue: 0.88))
        .padding(20)
        .frame(width: 440)
        .background(background)
        .onAppear {
            if session.kind == .secret {
                DispatchQueue.main.async { answerFocused = true }
            }
        }
    }
}

private enum SSHAskpass {
    static func run() {
        let message = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard !message.isEmpty else { Darwin.exit(1) }

        let environment = ProcessInfo.processInfo.environment
        let session = PromptSession(
            message: message,
            destination: environment["GHOSTTY_SSH_DESTINATION"],
            hint: environment["SSH_ASKPASS_PROMPT"])

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: session.kind == .hostKey ? 300 : 245),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.title = session.kind.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.delegate = session
        panel.contentView = NSHostingView(rootView: PromptView(session: session))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
        Darwin.exit(1)
    }
}

SSHAskpass.run()
