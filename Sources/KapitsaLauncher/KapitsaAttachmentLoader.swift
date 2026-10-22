import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Turns files into chat attachments with Apple frameworks only. Images are scaled down and
/// sent to Kapitsa as pictures; documents are sent as their text, since Kapitsa reads text
/// and images but not document files.
enum KapitsaAttachmentLoader {
    /// Larger images are scaled so their longest side is this many pixels. Kapitsa resizes
    /// images again itself; this keeps requests small.
    static let maxImageSide = 2048
    /// About 50K tokens of English. Longer documents are cut, and the message says so.
    static let maxDocumentCharacters = 200_000
    static let maxFileBytes = 50_000_000

    enum LoadError: LocalizedError {
        case tooLarge(String)
        case unreadable(String)
        case noText(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): return "\(name) is larger than 50 MB."
            case .unreadable(let name): return "Can't read \(name). Attach images, PDFs, Word, RTF, HTML or text files."
            case .noText(let name): return "\(name) has no text to send. A scanned PDF needs text recognition first."
            }
        }
    }

    static func load(_ url: URL) throws -> KapitsaChatAttachment {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxFileBytes { throw LoadError.tooLarge(name) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data

        if type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url) else { throw LoadError.unreadable(name) }
            return try imageAttachment(image, name: name)
        }
        let text: String?
        if type.conforms(to: .pdf) {
            text = PDFDocument(url: url)?.string
        } else if let documentType = attributedDocumentType(for: type) {
            text = try? NSAttributedString(url: url, options: [.documentType: documentType],
                                           documentAttributes: nil).string
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type == .data || type.conforms(to: .json) {
            text = try? String(contentsOf: url, encoding: .utf8)
        } else {
            text = nil
        }
        guard let text else { throw LoadError.unreadable(name) }
        return try documentAttachment(text, name: name)
    }

    static func imageAttachment(_ image: NSImage, name: String) throws -> KapitsaChatAttachment {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LoadError.unreadable(name)
        }
        let longest = max(cgImage.width, cgImage.height)
        let scale = longest > maxImageSide ? Double(maxImageSide) / Double(longest) : 1
        let width = max(1, Int(Double(cgImage.width) * scale)), height = max(1, Int(Double(cgImage.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw LoadError.unreadable(name)
        }
        // JPEG has no transparency, so transparent areas become white rather than black.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw LoadError.unreadable(name) }
        return KapitsaChatAttachment(name: name, kind: .image, imageData: jpeg, imageMIMEType: "image/jpeg")
    }

    static func documentAttachment(_ text: String, name: String) throws -> KapitsaChatAttachment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LoadError.noText(name) }
        let truncated = trimmed.count > maxDocumentCharacters
        return KapitsaChatAttachment(name: name, kind: .document,
                                     text: truncated ? String(trimmed.prefix(maxDocumentCharacters)) : trimmed,
                                     truncated: truncated)
    }

    private static func attributedDocumentType(for type: UTType) -> NSAttributedString.DocumentType? {
        if type.conforms(to: .rtfd) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: .html) { return .html }
        switch type.identifier {
        case "org.openxmlformats.wordprocessingml.document": return .officeOpenXML
        case "com.microsoft.word.doc": return .docFormat
        case "org.oasis-open.opendocument.text": return .openDocument
        case "com.microsoft.word.wordml": return .wordML
        default: return nil
        }
    }
}
