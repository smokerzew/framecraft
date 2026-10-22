import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One photo in the in-app library: the untouched original (camera RAW/HEIF/JPEG or an imported file),
/// plus the edit and framing as data. Edits never change the original file.
struct PhotoProject: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case camera, cameraRAW, cameraProRAW, imported }

    var id: UUID
    var created: Date
    var modified: Date
    var source: Source
    /// File name of the original inside the project folder.
    var originalFile: String
    var typeIdentifier: String?
    /// The camera's processed HEIF/JPEG that came with a RAW capture (kept for reference; edits use the RAW).
    var companionFile: String?
    var edit: EditState
    var finish = FinishSettings()

    var isRAW: Bool { source == .cameraRAW || source == .cameraProRAW }

    init(id: UUID = UUID(), created: Date = .now, source: Source, originalFile: String, typeIdentifier: String?,
         companionFile: String? = nil, edit: EditState) {
        self.id = id
        self.created = created
        self.modified = created
        self.source = source
        self.originalFile = originalFile
        self.typeIdentifier = typeIdentifier
        self.companionFile = companionFile
        self.edit = edit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .now
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .imported
        originalFile = try c.decode(String.self, forKey: .originalFile)
        typeIdentifier = try c.decodeIfPresent(String.self, forKey: .typeIdentifier)
        companionFile = try c.decodeIfPresent(String.self, forKey: .companionFile)
        edit = (try? c.decodeIfPresent(EditState.self, forKey: .edit)) ?? EditState()
        finish = (try? c.decodeIfPresent(FinishSettings.self, forKey: .finish)) ?? FinishSettings()
    }
}

enum ProjectError: LocalizedError {
    case storageFull, writeFailed, missingOriginal

    var errorDescription: String? {
        switch self {
        case .storageFull: "There isn't enough free storage to save this photo. Free up space and try again."
        case .writeFailed: "The photo couldn't be saved to the library."
        case .missingOriginal: "This photo's original file is missing, so it can't be opened."
        }
    }
}

/// Projects live in Application Support/Projects/<id>/ (project.json, the original, thumb.jpg).
/// Nothing is uploaded; deleting a project only removes the app's own copy, never a photo in Photos.
struct ProjectStore: Sendable {
    let directory: URL

    static let standard = ProjectStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Projects", isDirectory: true))

    func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func originalURL(_ project: PhotoProject) -> URL { folder(project.id).appendingPathComponent(project.originalFile) }
    func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumb.jpg") }
    private func jsonURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("project.json") }

    /// The project a file belongs to, if it's an original inside this store.
    func projectID(forOriginal url: URL) -> UUID? {
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return nil }
        return UUID(uuidString: parent.lastPathComponent)
    }

    func create(original: Data, typeIdentifier: String?, source: PhotoProject.Source, companion: Data? = nil,
                edit: EditState) throws -> PhotoProject {
        let id = UUID()
        let ext = typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
        var project = PhotoProject(id: id, source: source, originalFile: "original.\(ext)", typeIdentifier: typeIdentifier,
                                   companionFile: companion == nil ? nil : "camera.heic", edit: edit)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
            try original.write(to: originalURL(project), options: .atomic)
            if let companion { try companion.write(to: folder(id).appendingPathComponent("camera.heic"), options: .atomic) }
            project.modified = .now
            try write(project)
        } catch {
            try? fm.removeItem(at: folder(id))
            throw Self.map(error)
        }
        return project
    }

    func save(_ project: PhotoProject) throws {
        var copy = project
        copy.modified = .now
        do { try write(copy) } catch { throw Self.map(error) }
    }

    private func write(_ project: PhotoProject) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: jsonURL(project.id), options: .atomic)
    }

    func load(_ id: UUID) -> PhotoProject? {
        guard let data = try? Data(contentsOf: jsonURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PhotoProject.self, from: data)
    }

    /// Newest first. Projects whose original went missing are still listed, so they can be deleted.
    func list() -> [PhotoProject] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return ids.compactMap(UUID.init(uuidString:)).compactMap(load).sorted { $0.created > $1.created }
    }

    func hasOriginal(_ project: PhotoProject) -> Bool {
        FileManager.default.fileExists(atPath: originalURL(project).path)
    }

    /// A second, independent edit of the same photo (the original is copied so either can be deleted).
    func duplicate(_ project: PhotoProject) throws -> PhotoProject {
        guard let data = try? Data(contentsOf: originalURL(project)) else { throw ProjectError.missingOriginal }
        let companion = project.companionFile.flatMap { try? Data(contentsOf: folder(project.id).appendingPathComponent($0)) }
        var copy = try create(original: data, typeIdentifier: project.typeIdentifier, source: project.source,
                              companion: companion, edit: project.edit)
        copy.finish = project.finish
        copy.created = project.created.addingTimeInterval(0.001) // sorts right next to the source
        try save(copy)
        if let thumb = try? Data(contentsOf: thumbnailURL(project.id)) { try? thumb.write(to: thumbnailURL(copy.id)) }
        return copy
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    func writeThumbnail(_ image: CGImage, for id: UUID) {
        let url = thumbnailURL(id)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func map(_ error: Error) -> ProjectError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return .storageFull }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .storageFull }
        return .writeFailed
    }
}
