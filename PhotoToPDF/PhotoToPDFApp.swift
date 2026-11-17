import SwiftUI
import PhotosUI
import PDFKit

@main
struct PhotoToPDFApp: App {
    @StateObject private var store = PageStore()
    var body: some Scene { WindowGroup { ContentView(store: store) } }
}

private struct SharedPDF: Identifiable {
    let id = UUID()
    let url: URL
    var finishesCurrent = false
}

struct ContentView: View {
    @ObservedObject var store: PageStore
    @State private var quality = 100
    @State private var showCamera = false
    @State private var selected: [PhotosPickerItem] = []
    @State private var shared: SharedPDF?
    @State private var showHistory = false
    @State private var computerPDF: SharedPDF?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Название комплекта", text: $store.projectName)
                        .textFieldStyle(.roundedBorder)
                    Text("\(store.pages.count)").font(.system(size: 54, weight: .bold, design: .rounded))
                    Text("страниц в общем PDF").foregroundStyle(.secondary)
                    Text("Снимайте подряд. Каждый кадр сохраняется на iPhone.")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.padding()
                if store.pages.isEmpty {
                    Spacer()
                    Image(systemName: "doc.viewfinder").font(.system(size: 64)).foregroundStyle(.blue)
                    Text("Добавьте первые страницы").font(.headline).padding()
                    Spacer()
                } else {
                    List {
                        ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                            HStack(spacing: 14) {
                                PageThumbnail(url: store.url(for: page))
                                Text("Страница \(index + 1)").font(.headline)
                            }
                        }
                        .onDelete(perform: store.delete)
                        .onMove(perform: store.move)
                    }.listStyle(.plain)
                }
                VStack(spacing: 12) {
                    if store.busy {
                        ProgressView(value: store.progress)
                        Text(store.status).font(.footnote)
                    }
                    HStack {
                        Button { showCamera = true } label: {
                            Label("Снимать", systemImage: "camera.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        PhotosPicker(selection: $selected, maxSelectionCount: nil,
                                     selectionBehavior: .ordered, matching: .images) {
                            Label("Из фото", systemImage: "photo.on.rectangle")
                        }.buttonStyle(.bordered)
                    }
                    Picker("Качество PDF", selection: $quality) {
                        ForEach([100, 75, 50], id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }.pickerStyle(.segmented).accessibilityLabel("Качество PDF")
                    Button {
                        Task {
                            do { shared = SharedPDF(url: try await store.export(quality: quality), finishesCurrent: true) }
                            catch { store.error = error.localizedDescription }
                        }
                    } label: {
                        Label("Собрать PDF и сохранить", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.indigo)
                        .disabled(store.pages.isEmpty)
                    Button {
                        Task {
                            do { computerPDF = SharedPDF(url: try await store.export(quality: quality)) }
                            catch { store.error = error.localizedDescription }
                        }
                    } label: {
                        Label("Отправить на компьютер", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(store.pages.isEmpty)
                    Text("PDF: A4 · 1 фото = 1 страница · без ограничения 200 страниц")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Фото → PDF")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showHistory = true } label: { Label("История", systemImage: "clock.arrow.circlepath") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    EditButton().disabled(store.pages.isEmpty)
                    Button(role: .destructive) { confirmClear = true } label: {
                        Image(systemName: "trash")
                    }.disabled(store.pages.isEmpty).accessibilityLabel("Очистить все снимки")
                }
            }
            .disabled(store.busy || !store.ready)
            .fullScreenCover(isPresented: $showCamera) {
                CameraScreen(store: store)
            }
            .sheet(item: $shared) { item in
                ShareSheet(url: item.url) { completed, error in
                    shared = nil
                    if let error { store.error = error.localizedDescription }
                    else if completed && item.finishesCurrent { store.startNewProject() }
                }
            }
            .sheet(isPresented: $showHistory) { ProjectHistory(store: store) }
            .sheet(item: $computerPDF) { item in ComputerTransferView(url: item.url) }
            .confirmationDialog("Начать новый комплект?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить все снимки и начать новый", role: .destructive) { store.startNewProject() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все снимки текущего комплекта будут удалены. Собранные PDF останутся в истории.")
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(
                get: { store.error != nil }, set: { if !$0 { store.error = nil } }
            )) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
            .onChange(of: selected) { items in
                guard !items.isEmpty else { return }
                store.busy = true
                store.progress = 0
                store.status = "Импорт фотографий"
                Task {
                    defer { store.busy = false; selected = [] }
                    do {
                        for (index, item) in items.enumerated() {
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                throw AppFailure.message("Не удалось загрузить фото \(index + 1). Уже добавленные страницы сохранены.")
                            }
                            try await store.add(data)
                            store.progress = Double(index + 1) / Double(items.count)
                        }
                    } catch { store.error = error.localizedDescription }
                }
            }
        }
    }
}

private struct PageThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 54, height: 72)
        .task(id: url) {
            let result = await Task.detached(priority: .utility) {
                ImageFiles.thumbnail(at: url, size: 160).map { UIImage(cgImage: $0) }
            }.value
            image = result
        }
        .onDisappear { image = nil }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    var onComplete: (Bool, Error?) -> Void = { _, _ in }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            DispatchQueue.main.async { onComplete(completed, error) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ProjectHistory: View {
    @ObservedObject var store: PageStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock").font(.largeTitle)
                        Text("Пока нет собранных PDF")
                    }.foregroundStyle(.secondary)
                } else {
                    List(store.history) { project in
                        NavigationLink {
                            PDFProjectView(project: project)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(project.title).font(.headline)
                                Text("\(project.pageCount) стр. · \(project.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("История проектов")
            .toolbar { Button("Готово") { dismiss() } }
        }
    }
}

private struct PDFProjectView: View {
    let project: PDFProject
    @State private var share = false
    @State private var sendToComputer = false
    var body: some View {
        PDFPreview(url: project.url)
            .navigationTitle(project.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup {
                    Button { sendToComputer = true } label: { Image(systemName: "desktopcomputer") }
                    Button { share = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(isPresented: $sendToComputer) { ComputerTransferView(url: project.url) }
            .sheet(isPresented: $share) {
                ShareSheet(url: project.url) { _, _ in share = false }
            }
    }
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
