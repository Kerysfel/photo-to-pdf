import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct PDFSmoke {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSmoke-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        let jpeg = folder.appendingPathComponent("page.jpg")
        let encoder = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, bitmap.makeImage()!, nil)
        guard CGImageDestinationFinalize(encoder) else { fatalError("JPEG generation failed") }
        let pdf = folder.appendingPathComponent("240-pages.pdf")
        try await PDFExport.write(Array(repeating: jpeg, count: 240), to: pdf) { _ in }
        guard let result = CGPDFDocument(pdf as CFURL), result.numberOfPages == 240,
              result.page(at: 1) != nil, result.page(at: 240) != nil else {
            fatalError("Wrong page count")
        }
        print("PASS: exported and reopened 240-page PDF")
        let broken = folder.appendingPathComponent("broken.pdf")
        do {
            try await PDFExport.write([jpeg, folder.appendingPathComponent("missing.jpg")], to: broken) { _ in }
            fatalError("Missing image should fail")
        } catch {
            guard !FileManager.default.fileExists(atPath: broken.path),
                  !FileManager.default.fileExists(atPath: broken.appendingPathExtension("partial").path) else {
                fatalError("Partial PDF was left behind")
            }
            print("PASS: missing image fails without publishing partial PDF")
        }
    }
}
