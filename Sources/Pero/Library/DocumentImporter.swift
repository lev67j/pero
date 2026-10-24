import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns any supported file into PDF data. Everything in the library is a PDF,
/// so the pen works the same on all of them.
@MainActor
enum DocumentImporter {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let plainTextExtensions: Set<String> = ["txt", "text", "md", "markdown"]
    static let richTextExtensions: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt", "html", "htm"]

    static var allExtensions: Set<String> {
        imageExtensions.union(plainTextExtensions).union(richTextExtensions).union(["pdf"])
    }

    static var contentTypes: [UTType] {
        allExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func isSupported(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    static func makePDF(from url: URL) throws -> Data {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return try pdf(url) }
        if imageExtensions.contains(ext) { return try imagePDF(url) }
        if plainTextExtensions.contains(ext) { return try paginate(plainText(url), name: url.lastPathComponent) }
        if richTextExtensions.contains(ext) { return try paginate(richText(url), name: url.lastPathComponent) }
        throw PeroError.unsupportedFormat(ext)
    }

    // MARK: - PDF

    private static func pdf(_ url: URL) throws -> Data {
        guard let document = PDFDocument(url: url) else { throw PeroError.cannotOpen(url.lastPathComponent) }
        if document.isLocked && !document.unlock(withPassword: "") { throw PeroError.lockedPDF }
        return try Data(contentsOf: url)
    }

    // MARK: - Images

    /// Each image becomes an A4-wide page; multi-page TIFF scans keep all pages.
    private static func imagePDF(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PeroError.conversionFailed(url.lastPathComponent)
        }
        let ext = url.pathExtension.lowercased()
        let frameCount = (ext == "tif" || ext == "tiff") ? CGImageSourceGetCount(source) : 1
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PeroError.conversionFailed(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        var pages = 0
        for i in 0..<max(frameCount, 1) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary),
                  image.width > 0, image.height > 0 else { continue }
            let width: CGFloat = 595
            let height = width * CGFloat(image.height) / CGFloat(image.width)
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else { throw PeroError.conversionFailed(url.lastPathComponent) }
        return data as Data
    }

    // MARK: - Text

    private static func plainText(_ url: URL) throws -> NSAttributedString {
        let text: String
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            text = s
        } else if let s = try? String(contentsOf: url, encoding: .windowsCP1251) {
            text = s
        } else if let s = try? String(contentsOf: url, encoding: .utf16) {
            text = s
        } else {
            throw PeroError.conversionFailed(url.lastPathComponent)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        paragraph.lineHeightMultiple = 1.15
        return NSAttributedString(string: text, attributes: [
            // Not the system font: in printed PDFs its Cyrillic "к" is extracted as "ĸ",
            // which breaks copying and search.
            .font: NSFont(name: "Helvetica Neue", size: 12) ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
    }

    private static func richText(_ url: URL) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            // HTML without <meta charset> would otherwise be read as Latin-1.
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let text = try NSMutableAttributedString(url: url, options: options, documentAttributes: nil)
        // Text without an explicit color would print in the system text color.
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        return text
    }

    /// Lays text out on A4 pages and returns the PDF.
    private static func paginate(_ text: NSAttributedString, name: String) throws -> Data {
        let paper = NSSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output,
        ])
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = paper.width - 2 * margin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.appearance = NSAppearance(named: .aqua)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: width, height: 0)
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(text)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw PeroError.conversionFailed(name)
        }
        return data
    }
}
