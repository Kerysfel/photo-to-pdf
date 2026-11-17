import SwiftUI
import AVFoundation

struct ComputerTransferView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var cameraAllowed: Bool?
    @State private var invitation: ReceiverInvitation?
    @State private var transfer: ComputerTransfer?
    @State private var task: Task<Void, Never>?
    @State private var status = "Отсканируйте QR-код на экране своего компьютера."
    @State private var progress = 0.0
    @State private var finished = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if invitation == nil && cameraAllowed == true {
                    QRScanner { code in
                        do {
                            invitation = try ReceiverInvitation.parse(code)
                            status = "Подключение к компьютеру…"
                            start()
                        } catch { status = error.localizedDescription }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if cameraAllowed == false {
                    Text("Разрешите доступ к камере в настройках приложения.")
                    Button("Открыть настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Text(status).multilineTextAlignment(.center)
                if invitation != nil && !finished { ProgressView(value: progress) }
                if finished { Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green) }
                Spacer()
            }
            .padding()
            .navigationTitle("Отправить на компьютер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(finished ? "Готово" : "Отмена") { task?.cancel(); transfer?.cancel(); dismiss() } }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: cameraAllowed = true
                case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
                default: cameraAllowed = false
                }
            }
            .onDisappear { task?.cancel(); transfer?.cancel() }
        }
    }

    private func start() {
        guard let invitation else { return }
        let sender = ComputerTransfer(invitation: invitation)
        transfer = sender
        task = Task {
            do {
                status = "Подтвердите получение на компьютере."
                try await sender.send(url: url, invitation: invitation) { value in
                    Task { @MainActor in if !finished { progress = value; status = "Передача PDF…" } }
                }
                status = "Компьютер подтвердил сохранение PDF."
                finished = true
            } catch {
                status = "Не удалось отправить: \(error.localizedDescription) Если связь оборвалась, проверьте папку компьютера: файл мог сохраниться. Для повтора откройте новый QR-код."
                self.invitation = nil
            }
            transfer = nil
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController(onCode: onCode) }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) { controller.stop() }
}

private final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "PhotoToPDF.qr-camera")
    private let onCode: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        queue.async { [session] in session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { [session] in if session.isRunning { session.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true
        onCode(code)
        // Invalid codes remain scannable without reopening the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.delivered = false }
    }
}
