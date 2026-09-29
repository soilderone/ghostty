import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Loads the image for the preview.
///
/// A decoded image costs four bytes per pixel however small its file is: a 27-megapixel PNG is
/// well over 100 MB in memory, for a pane a few hundred points wide. Bitmaps of the formats
/// that have to be decoded whole and are larger than `maxPixelSize` are decoded at a smaller
/// size instead. They are still reported at the size of the whole image, so the preview shows
/// the same dimensions. Everything else is loaded as it always was: JPEG, for one, the system
/// already decodes at the size it is drawn, which is cheaper than this.
enum FilePreviewImage {
    /// The longest side, in pixels, that an image is kept at.
    static let maxPixelSize = 3072

    /// The formats that are decoded whole, which measured much cheaper when downsampled.
    private static let downsampledTypes = Set([UTType.png, .tiff, .bmp, .heic, .heif].map(\.identifier))

    static func load(contentsOf url: URL) -> NSImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = downsampled(source) {
            return image
        }
        return NSImage(contentsOf: url)
    }

    static func load(data: Data) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = downsampled(source) {
            return image
        }
        return NSImage(data: data)
    }

    /// The image at a smaller size, or nil when it doesn't need one, isn't of a format this helps
    /// with, or ImageIO can't decode it (SVG, for one), and the system's own loader should handle it.
    private static func downsampled(_ source: CGImageSource) -> NSImage? {
        guard CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              downsampledTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixelSize else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Photos are often stored sideways with a note to turn them.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Decode now, on this thread, rather than the first time the image is drawn.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        // The size of the whole image in points, as the system would report it: the pixels
        // scaled by the file's resolution, with 72 dpi being one pixel to the point.
        let scale = CGFloat(maxPixelSize) / CGFloat(max(width, height))
        let resolution = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let points = 72 / CGFloat(resolution)
        return NSImage(cgImage: thumbnail, size: NSSize(
            width: (CGFloat(thumbnail.width) / scale * points).rounded(),
            height: (CGFloat(thumbnail.height) / scale * points).rounded()))
    }
}
