import UIKit
import UniformTypeIdentifiers

/// "Share" > Porridge: saves the link and closes at once. Loading the page and summarizing it is done by the app.
final class ShareViewController: UIViewController {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.15)

        card.layer.cornerRadius = 22
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.text = "Saving …"
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -24),
        ])

        Task { await save() }
    }

    private func save() async {
        var address: URL?
        var title: String?
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            title = title ?? item.attributedTitle?.string ?? item.attributedContentText?.string
            for provider in item.attachments ?? [] where address == nil {
                address = await url(from: provider)
            }
        }

        guard let address else { return finish("No link found", success: false) }
        // The title is only useful when it is not the address itself.
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = cleanTitle.flatMap { $0.isEmpty || $0.hasPrefix("http") ? nil : String($0.prefix(300)) }
        do {
            try LinkInbox.add(.init(url: address.absoluteString, title: usable, date: Date()))
            finish("Saved to Porridge", success: true)
        } catch {
            finish("Could not save", success: false)
        }
    }

    private func url(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
            if let url = item as? URL { return url }
            if let url = (item as? NSURL) as URL? { return url }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
           let text = item as? String,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            return match.url
        }
        return nil
    }

    private func finish(_ message: String, success: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = (success ? "✓  " : "") + message
        Task {
            try? await Task.sleep(nanoseconds: success ? 800_000_000 : 1_600_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
