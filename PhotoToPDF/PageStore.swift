import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct PDFProject: Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    let pageCount: Int
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct PageRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let filename: String
}

enum ImageFiles {
    static func thumbnail(at url: URL, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    // Only one image is decoded at a time; EXIF orientation is baked into the JPEG.
    static func save(_ data: Data, to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw AppFailure.message("Не удалось прочитать фотографию.")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw AppFailure.message("Не удалось подготовить JPEG.") }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AppFailure.message("Не удалось сохранить фотографию.")
        }
        try (encoded as Data).write(to: url, options: .atomic)
    }
}

@MainActor
final class PageStore: ObservableObject {
    @Published private(set) var pages: [PageRecord] = []
    @Published private(set) var history: [PDFProject] = []
    @Published var projectName = UserDefaults.standard.string(forKey: "currentProjectName") ?? "Новый комплект" {
        didSet { UserDefaults.standard.set(projectName, forKey: "currentProjectName") }
    }
    @Published var error: String?
    @Published private(set) var ready = false
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = ""
    let root: URL
    private var manifest: URL { root.appendingPathComponent("pages.json") }

    init(documentsDirectory: URL? = nil) {
        root = (documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Pages", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                pages = try JSONDecoder().decode([PageRecord].self, from: Data(contentsOf: manifest))
            }
            for page in pages {
                let original = root.appendingPathComponent(page.filename)
                let quarantined = original.appendingPathExtension("deleted")
                if !FileManager.default.fileExists(atPath: original.path),
                   FileManager.default.fileExists(atPath: quarantined.path) {
                    try FileManager.default.moveItem(at: quarantined, to: original)
                }
            }
            // Recover a photo saved just before an interrupted manifest write.
            let known = Set(pages.map(\.filename))
            let extras = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil).filter {
                    $0.pathExtension == "jpg" && !known.contains($0.lastPathComponent)
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            pages += extras.map { PageRecord(id: UUID(), filename: $0.lastPathComponent) }
            try persist(pages)
            ready = true
            try loadHistory()
        } catch { self.error = "Не удалось открыть сохранённую сессию: \(error.localizedDescription)" }
    }

    func url(for page: PageRecord) -> URL { root.appendingPathComponent(page.filename) }

    private var exports: URL { root.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true) }

    func loadHistory() throws {
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        history = try FileManager.default.contentsOfDirectory(at: exports,
            includingPropertiesForKeys: [.creationDateKey]).filter { $0.pathExtension.lowercased() == "pdf" }
            .compactMap { url in
                guard let pdf = CGPDFDocument(url as CFURL) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return PDFProject(url: url, date: date, pageCount: pdf.numberOfPages)
            }.sorted { $0.date > $1.date }
    }

    // Move the entire session as one operation. Old JPEGs cannot be recovered
    // into the new session. Remove them only after the empty session is persisted.
    func startNewProject() {
        guard !busy, ready else { return }
        let archive = root.deletingLastPathComponent().appendingPathComponent("ArchivedPages", isDirectory: true)
        let old = archive.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: old)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try persist([])
            } catch {
                try? FileManager.default.removeItem(at: root)
                try FileManager.default.moveItem(at: old, to: root)
                throw error
            }
            pages = []
            projectName = "Новый комплект"
            try? FileManager.default.removeItem(at: old)
        } catch { self.error = "Не удалось начать новый комплект: \(error.localizedDescription)" }
    }

    private func persist(_ value: [PageRecord]) throws {
        try JSONEncoder().encode(value).write(to: manifest, options: .atomic)
    }

    func add(_ data: Data) async throws {
        guard ready else { throw AppFailure.message("Сессия недоступна. Перезапустите приложение.") }
        let id = UUID()
        let filename = String(format: "%.0f", Date().timeIntervalSince1970 * 1000) + "-\(id).jpg"
        let target = root.appendingPathComponent(filename)
        try await Task.detached(priority: .userInitiated) {
            try ImageFiles.save(data, to: target)
        }.value
        let next = pages + [PageRecord(id: id, filename: filename)]
        // If writing the manifest fails, keep the JPEG for recovery on next launch.
        try persist(next)
        pages = next
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { pages[$0] }
        var next = pages
        next.remove(atOffsets: offsets)
        do {
            // Quarantine files first, so interrupted deletion cannot recover them as new pages.
            var renamed: [(URL, URL)] = []
            do {
                for page in removed {
                    let source = url(for: page)
                    if FileManager.default.fileExists(atPath: source.path) {
                        let trash = source.appendingPathExtension("deleted")
                        try FileManager.default.moveItem(at: source, to: trash)
                        renamed.append((source, trash))
                    }
                }
                try persist(next)
            } catch {
                for (source, trash) in renamed { try? FileManager.default.moveItem(at: trash, to: source) }
                throw error
            }
            pages = next
            for (_, trash) in renamed { try? FileManager.default.removeItem(at: trash) }
        } catch { self.error = error.localizedDescription }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var next = pages
        next.move(fromOffsets: offsets, toOffset: destination)
        do { try persist(next); pages = next }
        catch { self.error = error.localizedDescription }
    }

    func export(quality: Int = 100) async throws -> URL {
        let inputs = pages.map { url(for: $0) }
        guard !inputs.isEmpty else { throw AppFailure.message("Сначала добавьте фотографии.") }
        busy = true
        progress = 0
        status = "Сборка PDF"
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = previousIdle }
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let cleaned = projectName.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.isEmpty ? "Комплект" : String(cleaned.prefix(70))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let destination = exports.appendingPathComponent("\(title) — \(formatter.string(from: Date())) — \(UUID().uuidString.prefix(6)).pdf")
        let result = try await Task.detached(priority: .userInitiated) {
            try await PDFExport.write(inputs, to: destination, quality: quality) { fraction in
                await MainActor.run { self.progress = fraction }
            }
            return destination
        }.value
        try loadHistory()
        return result
    }
}
