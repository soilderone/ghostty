import AppKit
import SwiftUI

/// A key that a `CommandTextField` hands to its owner instead of its field editor.
enum TextFieldCommand {
    case submit
    case cancel
    case complete
    case moveUp
    case moveDown
}

/// A borderless text field that reports return, escape, tab and the up and down arrows, for
/// fields with a list of suggestions under them.
///
/// Keys pressed while an input method is composing go to the input method, so confirming a
/// candidate with return doesn't also submit the field.
struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 12)
    var focusOnAppear = false

    /// Handles a key, and returns whether it did.
    var onCommand: (TextFieldCommand) -> Bool = { _ in false }
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = ChromePalette.text
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator

        if focusOnAppear {
            // The field isn't in a window until SwiftUI has placed it.
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                let end = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        guard field.stringValue != text else { return }

        // Replacing the text through the field editor keeps the field focused, with the caret
        // at the end as after completing in a shell.
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        } else {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandTextField

        init(_ parent: CommandTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }

            let command: TextFieldCommand
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): command = .submit
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            case #selector(NSResponder.insertTab(_:)): command = .complete
            case #selector(NSResponder.moveUp(_:)): command = .moveUp
            case #selector(NSResponder.moveDown(_:)): command = .moveDown
            default: return false
            }
            return parent.onCommand(command)
        }
    }
}
