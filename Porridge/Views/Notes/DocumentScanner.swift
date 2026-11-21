import SwiftUI
import UIKit
import VisionKit

/// The system's document camera: finds the page's edges, straightens it and takes as many pages as the user scans.
/// The pages become one PDF, which comes in like a PDF picked from Files: its text is read and it is summarized.
struct DocumentScanner: UIViewControllerRepresentable {
    /// The PDF of the scanned pages, in a temporary folder; nil when the scan was cancelled or failed.
    let onFinish: (URL?) -> Void

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
        let onFinish: (URL?) -> Void

        init(onFinish: @escaping (URL?) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onFinish(ScannedPDF.write(pages, title: scan.title))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("[scan] failed: \(error.localizedDescription)")
            onFinish(nil)
        }
    }
}

/// Scanned pages as one PDF: each page as large as A4 is wide, the picture as JPEG so a page stays small.
enum ScannedPDF {
    /// The width of an A4 page in points.
    static let pageWidth: CGFloat = 595

    static func write(_ pages: [UIImage], title: String) -> URL? {
        guard !pages.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Scans/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(title: title))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 297 / 210))
        do {
            try renderer.writePDF(to: url) { context in
                for page in pages {
                    // Re-encoded as JPEG: drawn as it comes from the camera, a page would be stored uncompressed.
                    let image = page.jpegData(compressionQuality: 0.7).flatMap(UIImage.init(data:)) ?? page
                    let size = image.size
                    guard size.width > 0, size.height > 0 else { continue }
                    let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * size.height / size.width)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
        } catch {
            print("[scan] not written: \(error.localizedDescription)")
            return nil
        }
        return url
    }

    /// "Scan 21 Nov 2026 at 14.32.pdf"; the camera's own title ("Scanned Document") says nothing.
    static func fileName(title: String, date: Date = Date()) -> String {
        let generic = title.isEmpty || title.hasPrefix("Scanned Document") || title.hasPrefix("Gescanntes Dokument")
        let name = generic ? String(localized: "Scan \(date.formatted(date: .abbreviated, time: .shortened))") : title
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + ".pdf"
    }
}
