/// ImageSourceService.swift - concrete implementation of the `ImageSourceService` protocol.
///
/// Wraps `FileManager` to stat a local image file and return its byte length.
/// Performs no hashing and no disk-safety logic; those belong in other services.
/// Throws `CoreError.badInput` when the file is missing or unreadable.
///
/// No SwiftUI/AppKit.
import Foundation

// MARK: - DefaultImageSourceService

/// The concrete `ImageSourceService` implementation shipped by USBImagerCore.
///
/// Uses `FileManager.default` to read file attributes. In unit tests that write
/// a real temporary file under `/tmp`, no injection is needed: the service reads
/// the real filesystem and the test controls the file contents.
public struct DefaultImageSourceService: ImageSourceService {

    // MARK: - Init

    /// Create the service. No configuration is required.
    public init() {}

    // MARK: - ImageSourceService conformance

    /// Return the byte length of the file at `url`.
    ///
    /// Reads `NSFileSize` from `FileManager` file attributes. Throws
    /// `CoreError.badInput` when the path does not exist, is not a regular
    /// file, is a directory, or cannot be read.
    ///
    /// - Parameter url: a `file:`-backed URL to a local image file.
    /// - Returns: the file byte length as an `Int`.
    /// - Throws: `CoreError.badInput(message:)` when the file is missing or
    ///   unreadable.
    public func byteLength(of url: URL) throws -> Int {
        let path = url.path
        // Use FileManager to fetch the file size attribute.
        // If the file is missing or inaccessible, attributesOfItem throws.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw CoreError.badInput(message: "Cannot read file at \"\(path)\": \(error.localizedDescription).")
        }
        // Confirm the item is a regular file, not a directory or device node.
        let fileType = attributes[.type] as? FileAttributeType
        guard fileType == .typeRegular else {
            throw CoreError.badInput(message: "Path \"\(path)\" is not a regular file.")
        }
        // NSFileSize returns UInt64; convert to Int (image sizes fit in signed 64-bit).
        let sizeValue = attributes[.size] as? UInt64
        guard let size = sizeValue else {
            throw CoreError.badInput(message: "Could not read file size for \"\(path)\".")
        }
        return Int(size)
    }
}
