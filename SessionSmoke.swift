import SwiftUI

@main
struct SessionTests: App {
    var body: some Scene {
        WindowGroup { Text("Session tests").task { await run() } }
    }
    @MainActor func run() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let isolated = docs.appendingPathComponent(UUID().uuidString)
        let result = docs.appendingPathComponent("results.txt")
        do {
            let store = PageStore(documentsDirectory: isolated)
            guard store.ready else { throw AppFailure.message("Not ready") }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 180))
            let image = renderer.image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
            }
            let data = image.jpegData(compressionQuality: 0.8)!
            try await store.add(data)
            try await store.add(data)
            store.projectName = "Тестовый проект"
            let pdf = try await store.export()
            guard store.pages.count == 2, store.history.count == 1,
                  store.history[0].pageCount == 2 else { throw AppFailure.message("Export/history mismatch") }
            let originals = store.pages.map { store.url(for: $0) }
            store.startNewProject()
            guard store.pages.isEmpty, originals.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }),
                  FileManager.default.fileExists(atPath: pdf.path), store.history.count == 1 else {
                throw AppFailure.message("Clear lost history or kept old pages")
            }
            let restored = PageStore(documentsDirectory: isolated)
            guard restored.ready, restored.pages.isEmpty, restored.history.count == 1 else {
                throw AppFailure.message("Restart did not preserve empty session and history")
            }
            try await restored.add(data)
            _ = try await restored.export()
            guard restored.pages.count == 1, restored.history.count == 2 else {
                throw AppFailure.message("New session mixes old pages")
            }
            let legacy = pdf.deletingLastPathComponent().appendingPathComponent("Страницы-old.pdf")
            try FileManager.default.copyItem(at: pdf, to: legacy)
            try restored.loadHistory()
            guard restored.history.count == 3 else { throw AppFailure.message("Legacy PDF migration failed") }
            guard let legacyProject = restored.history.first(where: { $0.url == legacy }) else {
                throw AppFailure.message("Legacy project missing")
            }
            let currentPhoto = restored.url(for: restored.pages[0])
            try restored.deleteProject(legacyProject)
            guard !FileManager.default.fileExists(atPath: legacy.path),
                  FileManager.default.fileExists(atPath: pdf.path),
                  FileManager.default.fileExists(atPath: currentPhoto.path),
                  restored.history.count == 2 else { throw AppFailure.message("History deletion affected other files") }
            let afterDeletion = PageStore(documentsDirectory: isolated)
            guard afterDeletion.history.count == 2, afterDeletion.pages.count == 1 else {
                throw AppFailure.message("Deleted project returned after restart")
            }
            try "PASS: history deletion removes only selected PDF and persists after restart".write(to: result, atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL: \(error)".write(to: result, atomically: true, encoding: .utf8)
        }
    }
}
