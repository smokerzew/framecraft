import CoreImage
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, heic, png
    var id: String { rawValue }
    var label: String { self == .heic ? "HEIF" : rawValue.uppercased() }
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png: "png"
        }
    }
}

enum ExportError: LocalizedError {
    case decodeFailed, renderFailed, writeFailed, photosDenied, photosFailed

    var errorDescription: String? {
        switch self {
        case .decodeFailed: "The original photo couldn't be read."
        case .renderFailed: "The edited photo couldn't be rendered. Try JPEG."
        case .writeFailed: "The file couldn't be saved. Check available storage."
        case .photosDenied: "FrameCraft isn't allowed to add photos. Turn it on in Settings > Privacy & Security > Photos > FrameCraft."
        case .photosFailed: "Photos couldn't save the image."
        }
    }
}

struct ExportOptions: Equatable, Sendable {
    var format: ExportFormat = .jpeg
    var finish = FinishSettings()
    /// Leaves GPS location out of the exported copy (the original keeps it).
    var removeLocation = false
}

/// Renders the edit at full resolution from the original, adds the finish, keeps capture metadata,
/// and writes a file for the share sheet or Photos. The original is never modified.
struct ExportService: Sendable {
    var renderer: PhotoRenderer = .shared
    var directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)

    func render(original: Data, edit: EditState, options: ExportOptions) throws -> Data {
        guard let source = CIImage(data: original, options: [.applyOrientationProperty: true]) else { throw ExportError.decodeFailed }
        var image = renderer.render(edit, to: source)
        if !options.finish.isEmpty {
            image = FinishingRenderer.finish(image, settings: options.finish, metadata: CaptureMetadata(data: original), context: renderer.context)
        }
        image = image.settingProperties(Self.carriedMetadata(source.properties, removeLocation: options.removeLocation))
        return try renderer.encode(image, as: options.format, colorSpace: source.colorSpace)
    }

    func export(original: Data, edit: EditState, options: ExportOptions, date: Date = .now) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let data = try render(original: original, edit: edit, options: options)
            let fm = FileManager.default
            try? fm.removeItem(at: directory)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(Self.fileName(date: date, ext: options.format.fileExtension))
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                throw ExportError.writeFailed
            }
        }.value
    }

    static func fileName(date: Date, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "FrameCraft-\(formatter.string(from: date)).\(ext)"
    }

    /// Adds a finished file to Photos. Reports success only after Photos confirms it.
    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photosDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
        } catch {
            throw ExportError.photosFailed
        }
    }

    /// Capture metadata for the exported copy: camera, exposure and date stay; orientation is reset
    /// (the pixels are already upright), stale pixel sizes are dropped, and location goes if asked.
    static func carriedMetadata(_ properties: [String: Any], removeLocation: Bool) -> [String: Any] {
        var props: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary] as [CFString] {
            if let value = properties[key as String] { props[key as String] = value }
        }
        if removeLocation { props[kCGImagePropertyGPSDictionary as String] = nil }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = nil
            exif[kCGImagePropertyExifPixelYDimension as String] = nil
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props[kCGImagePropertyOrientation as String] = 1
        return props
    }
}
