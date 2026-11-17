import Foundation
import CoreGraphics
import ImageIO

enum PDFExport {
    private static func provider(for url: URL, quality: Int) -> CGDataProvider? {
        if quality == 100 { return CGDataProvider(url: url as CFURL) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: quality == 75 ? 2250 : 1500
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { return nil }
        return CGDataProvider(data: data)
    }

    static func write(_ inputs: [URL], to destination: URL,
                      quality: Int = 100, progress: @escaping (Double) async -> Void) async throws {
        let partial = destination.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        var paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(partial as CFURL, mediaBox: &paper, nil) else {
            throw AppFailure.message("Не удалось создать PDF. Проверьте свободное место.")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (index, source) in inputs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                // JPEG-backed images allow Core Graphics to preserve compressed image data.
                guard let provider = provider(for: source, quality: quality),
                      let image = CGImage(jpegDataProviderSource: provider, decode: nil,
                                          shouldInterpolate: true, intent: .defaultIntent) else {
                    throw AppFailure.message("Не удалось прочитать страницу \(index + 1). PDF не сохранён.")
                }
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(paper)
                let area = paper.insetBy(dx: 12, dy: 12)
                let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
                let width = CGFloat(image.width) * scale
                let height = CGFloat(image.height) * scale
                context.draw(image, in: CGRect(x: paper.midX - width / 2,
                    y: paper.midY - height / 2, width: width, height: height))
                context.endPDFPage()
            }
            await progress(Double(index + 1) / Double(inputs.count))
        }
        context.closePDF()
        closed = true
        guard let document = CGPDFDocument(partial as CFURL), document.numberOfPages == inputs.count else {
            throw AppFailure.message("PDF не прошёл проверку. Возможно, недостаточно места на iPhone.")
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
