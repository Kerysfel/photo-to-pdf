import Foundation
import Network
import Security
import CryptoKit

struct ReceiverInvitation: Decodable {
    let version: Int
    let host: String
    let port: UInt16
    let certificateSha256: String
    let secret: String

    static func parse(_ text: String) throws -> ReceiverInvitation {
        guard text.utf8.count <= 2048,
              let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              value.version == 1, value.port != 0,
              let secret = Data(base64Encoded: value.secret), secret.count == 32,
              value.certificateSha256.count == 64,
              value.certificateSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              isPrivateIPv4(value.host) else {
            throw AppFailure.message("QR-код приёмника недействителен.")
        }
        return value
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt8(part), String(number) == part else { return nil }
            return number
        }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1])) ||
            (numbers[0] == 192 && numbers[1] == 168) || (numbers[0] == 169 && numbers[1] == 254)
    }
}

private final class ConnectionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func finish(_ result: Result<Void, Error>, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let shouldResume = !completed
        completed = true
        lock.unlock()
        if shouldResume { continuation.resume(with: result) }
    }
}

final class ComputerTransfer {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PhotoToPDF.transfer")

    init(invitation: ReceiverInvitation) {
        let tls = NWProtocolTLS.Options()
        let fingerprint = invitation.certificateSha256
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate],
                  let certificate = chain.first else { complete(false); return }
            let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02x", $0) }.joined()
            complete(digest == fingerprint)
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host(invitation.host),
                                  port: NWEndpoint.Port(rawValue: invitation.port)!, using: parameters)
    }

    func cancel() { connection.cancel() }

    func send(url: URL, invitation: ReceiverInvitation, progress: @escaping (Double) -> Void) async throws {
        defer { connection.cancel() }
        let timeout = DispatchWorkItem { [connection] in connection.cancel() }
        queue.asyncAfter(deadline: .now() + 600, execute: timeout)
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await connect()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
                  size.int64Value <= 2_147_483_648 else {
                throw AppFailure.message("Размер PDF должен быть от 1 байта до 2 ГиБ.")
            }
            try await sendMessage(["secret": invitation.secret, "name": url.lastPathComponent, "size": size])
            guard try await readStatus() == "accepted" else {
                throw AppFailure.message("Получение отклонено на компьютере.")
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            var sent: Int64 = 0
            while sent < size.int64Value {
                try Task.checkCancellation()
                guard let data = try file.read(upToCount: Int(min(65_536, size.int64Value - sent))), !data.isEmpty else {
                    throw AppFailure.message("PDF изменился во время передачи.")
                }
                hash.update(data: data)
                try await write(data)
                sent += Int64(data.count)
                progress(Double(sent) / size.doubleValue)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try await sendMessage(["sha256": digest])
            guard try await readStatus() == "saved" else {
                throw AppFailure.message("Компьютер не подтвердил сохранение PDF.")
            }
        } onCancel: { self.connection.cancel() }
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = ConnectionResult()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: result.finish(.success(()), continuation: continuation)
                case .failed(let error), .waiting(let error): result.finish(.failure(error), continuation: continuation)
                case .cancelled: result.finish(.failure(CancellationError()), continuation: continuation)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: AppFailure.message(complete ? "Соединение закрыто." : "Пустой ответ компьютера.")) }
                }
            }
            result.append(data)
        }
        return result
    }

    private func sendMessage(_ object: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= 4096 else { throw AppFailure.message("Слишком длинное имя файла.") }
        var length = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try await write(header + body)
    }

    private func readStatus() async throws -> String {
        let header = try await readExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...4096).contains(length),
              let json = try JSONSerialization.jsonObject(with: await readExactly(Int(length))) as? [String: Any],
              let status = json["status"] as? String else {
            throw AppFailure.message("Некорректный ответ компьютера.")
        }
        return status
    }
}
