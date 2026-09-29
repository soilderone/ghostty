import AppKit
import AVKit
import PDFKit
import SwiftUI

/// The kinds of files the preview hands to the system's own viewers instead of the preview
/// page: PDFs, sound and video.
enum FilePreviewMedia: Equatable {
    case pdf
    case audio
    case video

    /// What AVFoundation plays without extra codecs.
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    init?(pathExtension: String) {
        let pathExtension = pathExtension.lowercased()
        if pathExtension == "pdf" {
            self = .pdf
        } else if Self.audioExtensions.contains(pathExtension) {
            self = .audio
        } else if Self.videoExtensions.contains(pathExtension) {
            self = .video
        } else {
            return nil
        }
    }
}

/// A PDF, sound or video in the preview. These play and scroll on their own, so they don't
/// need the preview page.
struct FileMediaPreview: View {
    let url: URL
    let media: FilePreviewMedia

    var body: some View {
        switch media {
        case .pdf:
            FilePDFPreview(url: url)
        case .audio:
            FileAudioPreview(url: url)
        case .video:
            FilePlayerView(url: url)
        }
    }
}

// MARK: PDF

private struct FilePDFPreview: View {
    let url: URL

    @State private var document: PDFDocument?
    @State private var problem: String?

    var body: some View {
        Group {
            if let problem {
                FileMessage(symbol: "exclamationmark.triangle", title: problem)
            } else {
                FilePDFView(document: document)
            }
        }
        .onAppear(perform: load)
        .onChange(of: url) { _ in load() }
    }

    private func load() {
        let document = PDFDocument(url: url)
        self.document = document
        if document == nil {
            problem = "Couldn't open the PDF"
        } else if document?.isLocked == true {
            problem = "This PDF is password protected"
        } else {
            problem = nil
        }
    }
}

private struct FilePDFView: NSViewRepresentable {
    let document: PDFDocument?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = ChromePalette.panel
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
    }
}

// MARK: Sound and video

private struct FileAudioPreview: View {
    let url: URL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                .lineLimit(1)
                .truncationMode(.middle)

            FilePlayerView(url: url)
                .frame(width: 320, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The system's player with its own controls. It doesn't start by itself, and stops when the
/// preview goes away or shows another file.
private struct FilePlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        guard current != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
