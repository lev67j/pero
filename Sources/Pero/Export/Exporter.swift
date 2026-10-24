import PDFKit

/// Produces ordinary PDFs with the handwriting burned into the pages.
enum Exporter {
    static func flattenedPDF(package: URL) throws -> Data {
        let name = package.deletingPathExtension().lastPathComponent
        guard let document = PDFDocument(url: DocumentPackage.pdfURL(package)) else {
            throw PeroError.cannotOpen(name)
        }
        let strokes = (try? DocumentPackage.loadInk(package)) ?? []

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PeroError.conversionFailed(name)
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let size = (rotation == 90 || rotation == 270) ? CGSize(width: box.height, height: box.width) : box.size
            var mediaBox = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &mediaBox)
            // draw(with:to:) applies the page's rotation and crop itself.
            page.draw(with: .cropBox, to: context)
            // Strokes are in page space, so they need the same rotation and crop.
            context.saveGState()
            page.transform(context, for: .cropBox)
            for stroke in strokes where stroke.page == index {
                stroke.draw(in: context)
            }
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
