import AppKit
import SwiftUI

@MainActor
struct WorkspaceEditorView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var document: WorkspaceDocument

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(model.documents) { doc in
                        HStack(spacing: 4) {
                            Button((doc.dirty ? "● " : "") + doc.title) { model.selectedDocument = doc.id }
                                .fontWeight(doc.id == document.id ? .semibold : .regular)
                            Button { model.closeDocument(doc) } label: { Image(systemName: "xmark") }
                                .help("Close file")
                        }.padding(6)
                    }
                }
            }
            HStack {
                Text("\(document.location.label): \(document.path)").font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Save") { model.save(document) }.disabled(document.saving || !document.dirty)
                Button("Save Copy…") {
                    guard let path = WorkspacePrompt.text("Save Copy — full path", value: document.path), path.hasPrefix("/") else { return }
                    model.save(document, copyPath: path)
                }.disabled(document.saving)
            }.padding(.horizontal, 8).padding(.bottom, 4)
            Divider()
            WorkspaceTextEditor(text: $document.text, save: { model.save(document) }).id(document.id)
        }
    }
}

@MainActor
private struct WorkspaceTextEditor: NSViewRepresentable {
    @Binding var text: String
    let save: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let editor = WorkspaceTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.usesFindBar = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.string = text
        editor.saveFile = save
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? WorkspaceTextView else { return }
        editor.saveFile = save
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WorkspaceTextEditor
        init(_ parent: WorkspaceTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class WorkspaceTextView: NSTextView {
    var saveFile: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            saveFile?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
