import Foundation

extension Data {
    /// The data as UTF-8 text, with any invalid bytes replaced by U+FFFD.
    ///
    /// For output that is mostly UTF-8 but can't be trusted to be all of it, such as a diff
    /// of a Latin-1 file or output that was cut off mid-character. One bad byte shouldn't
    /// lose the rest of the text.
    var lossyUTF8String: String {
        if let text = String(bytes: self, encoding: .utf8) { return text }

        // This initializer repairs invalid UTF-8 in what the closure writes.
        return String(unsafeUninitializedCapacity: count) { buffer in
            copyBytes(to: buffer)
        }
    }
}
