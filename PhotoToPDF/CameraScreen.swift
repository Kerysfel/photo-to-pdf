import SwiftUI
import AVFoundation

struct CameraScreen: View {
    @ObservedObject var store: PageStore
    @Environment(\.dismiss) private var dismiss
    @State private var allowed: Bool?

    var body: some View {
        Group {
            if allowed == true, UIImagePickerController.isSourceTypeAvailable(.camera) {
                ContinuousCamera(store: store) { dismiss() }.ignoresSafeArea()
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "camera.fill").font(.system(size: 60))
                    Text(allowed == nil ? "Проверяем доступ к камере…" : "Камера недоступна")
                        .font(.title2)
                    if allowed == false {
                        Text("Разрешите доступ к камере в настройках приложения. В симуляторе можно использовать импорт из «Фото».")
                            .multilineTextAlignment(.center)
                        Button("Открыть настройки") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    Button("Закрыть") { dismiss() }.buttonStyle(.bordered)
                }.padding()
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
        }
    }
}

// A custom shutter keeps the camera open after each photo instead of asking
// for confirmation and dismissing the picker after every page.
private struct ContinuousCamera: UIViewControllerRepresentable {
    @ObservedObject var store: PageStore
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onDone: onDone) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.cameraCaptureMode = .photo
        picker.showsCameraControls = false
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        let overlay = CameraOverlay(frame: picker.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.capture.addTarget(context.coordinator, action: #selector(Coordinator.capture), for: .touchUpInside)
        overlay.done.addTarget(context.coordinator, action: #selector(Coordinator.done), for: .touchUpInside)
        picker.cameraOverlayView = overlay
        context.coordinator.picker = picker
        context.coordinator.overlay = overlay
        context.coordinator.refresh()
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        context.coordinator.refresh()
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let store: PageStore
        let onDone: () -> Void
        weak var picker: UIImagePickerController?
        weak var overlay: CameraOverlay?
        private var saving = false

        init(store: PageStore, onDone: @escaping () -> Void) {
            self.store = store
            self.onDone = onDone
        }

        @MainActor func refresh() {
            overlay?.counter.text = saving ? "Сохраняем…" : "Сохранено страниц: \(store.pages.count)"
            overlay?.capture.isEnabled = !saving
            overlay?.capture.alpha = saving ? 0.4 : 1
            overlay?.done.isEnabled = !saving
        }

        @MainActor @objc func capture() {
            guard !saving else { return }
            saving = true
            refresh()
            picker?.takePicture()
        }

        @MainActor @objc func done() { if !saving { onDone() } }

        @MainActor func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            if !saving { onDone() }
        }

        @MainActor func imagePickerController(_ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.92) else {
                saving = false
                refresh()
                showError("Не удалось получить снимок. Попробуйте ещё раз.")
                return
            }
            Task { @MainActor in
                defer { saving = false; refresh() }
                do {
                    try await store.add(data)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } catch { showError(error.localizedDescription) }
            }
        }

        @MainActor private func showError(_ message: String) {
            let alert = UIAlertController(title: "Фото не добавлено", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            picker?.present(alert, animated: true)
        }
    }
}

private final class CameraOverlay: UIView {
    let capture = UIButton(type: .system)
    let done = UIButton(type: .system)
    let counter = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        counter.textColor = .white
        counter.font = .systemFont(ofSize: 18, weight: .semibold)
        counter.textAlignment = .center
        counter.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        counter.layer.cornerRadius = 14
        counter.clipsToBounds = true
        capture.setTitle("Снять страницу", for: .normal)
        capture.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        capture.setTitleColor(.black, for: .normal)
        capture.backgroundColor = .white
        capture.layer.cornerRadius = 30
        capture.accessibilityLabel = "Снять и сохранить страницу"
        done.setTitle("Готово", for: .normal)
        done.setTitleColor(.white, for: .normal)
        done.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        done.layer.cornerRadius = 12
        for element in [counter, capture, done] {
            element.translatesAutoresizingMaskIntoConstraints = false
            addSubview(element)
        }
        NSLayoutConstraint.activate([
            counter.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            counter.centerXAnchor.constraint(equalTo: centerXAnchor),
            counter.widthAnchor.constraint(equalToConstant: 270),
            counter.heightAnchor.constraint(equalToConstant: 44),
            capture.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            capture.centerXAnchor.constraint(equalTo: centerXAnchor),
            capture.widthAnchor.constraint(equalToConstant: 220),
            capture.heightAnchor.constraint(equalToConstant: 64),
            done.bottomAnchor.constraint(equalTo: capture.topAnchor, constant: -16),
            done.centerXAnchor.constraint(equalTo: centerXAnchor),
            done.widthAnchor.constraint(equalToConstant: 100),
            done.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Leave the preview available for the camera's native tap-to-focus gesture.
        return hit === self || hit === counter ? nil : hit
    }
}
