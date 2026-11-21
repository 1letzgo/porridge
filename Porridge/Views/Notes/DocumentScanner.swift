import SwiftUI
import UIKit
import VisionKit

/// The system's document camera: finds the page's edges, straightens it and takes as many pages as the user scans.
/// The pages become one PDF, which comes in like a PDF picked from Files: its text is read and it is summarized.
struct DocumentScanner: UIViewControllerRepresentable {
    /// The PDF of the scanned pages, in a temporary folder; nil when the scan was cancelled or failed. On the main actor.
    let onFinish: @MainActor (URL?) -> Void

    /// The camera can scan here (not in the Simulator, not without a camera).
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: @MainActor (URL?) -> Void

        init(onFinish: @escaping @MainActor (URL?) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // Written away from the main thread, one page at a time: a long scan at full resolution would freeze the
            // screen and could cost the app its memory.
            let pages = ScanPages(scan: scan)
            let onFinish = onFinish
            Task.detached(priority: .userInitiated) {
                let url = ScannedPDF.write(pageCount: pages.scan.pageCount, title: pages.scan.title) { pages.scan.imageOfPage(at: $0) }
                await MainActor.run { onFinish(url) }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            MainActor.assumeIsolated { onFinish(nil) }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("[scan] failed: \(error.localizedDescription)")
            MainActor.assumeIsolated { onFinish(nil) }
        }
    }

    /// The scan handed to the background task; it is only read there, after the camera let go of it.
    private struct ScanPages: @unchecked Sendable {
        let scan: VNDocumentCameraScan
    }
}

/// Scanned pages as one PDF: each page as large as A4 is wide, the picture at about 144 dpi as JPEG so a page stays small.
enum ScannedPDF {
    /// The width of an A4 page in points.
    static let pageWidth: CGFloat = 595
    /// Pixels across a page: twice its width in points, enough to read and to recognize text.
    static let pixelWidth: CGFloat = pageWidth * 2

    static func write(_ pages: [UIImage], title: String) -> URL? {
        write(pageCount: pages.count, title: title) { pages[$0] }
    }

    /// Asks for one page at a time and lets go of it before the next, so memory stays at one page.
    static func write(pageCount: Int, title: String, page: (Int) -> UIImage) -> URL? {
        guard pageCount > 0 else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Scans/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(title: title))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 297 / 210))
        do {
            try renderer.writePDF(to: url) { context in
                for index in 0..<pageCount {
                    autoreleasepool {
                        guard let image = compressed(page(index)) else { return }
                        let size = image.size
                        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * size.height / size.width)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        image.draw(in: bounds)
                    }
                }
            }
        } catch {
            print("[scan] not written: \(error.localizedDescription)")
            return nil
        }
        return url
    }

    /// The page made smaller to `pixelWidth` (never larger) and re-encoded as JPEG: drawn as it comes from the
    /// camera, a page would be stored uncompressed at full size.
    static func compressed(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let pixels = size.width * image.scale
        let factor = min(1, pixelWidth / pixels)
        let target = CGSize(width: (pixels * factor).rounded(), height: (size.height * image.scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let smaller = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return smaller.jpegData(compressionQuality: 0.7).flatMap(UIImage.init(data:)) ?? smaller
    }

    /// "Scan 21 Nov 2026 at 14.32.pdf"; the camera's own title ("Scanned Document") says nothing.
    static func fileName(title: String, date: Date = Date()) -> String {
        let generic = title.isEmpty || title.hasPrefix("Scanned Document") || title.hasPrefix("Gescanntes Dokument")
        let name = generic ? String(localized: "Scan \(date.formatted(date: .abbreviated, time: .shortened))") : title
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + ".pdf"
    }
}
