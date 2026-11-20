import UIKit
import UniformTypeIdentifiers

/// "Share" > Porridge: saves what was shared (a link, text, images, PDFs, files, audio) into the app's inbox and
/// closes by itself. A bucket can be chosen before it does; "Undo" takes the share back. Reading
/// the page or the text in an image and summarizing is done by the app.
final class ShareViewController: UIViewController {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let buttons = UIStackView()
    private let bucketButton = UIButton(configuration: .gray())
    private let undoButton = UIButton(configuration: .plain())

    private var entry: ShareInbox.Entry?
    private var closing: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.15)

        card.layer.cornerRadius = 22
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = "Saving …"
        spinner.startAnimating()

        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.isHidden = true
        for button in [bucketButton] {
            button.showsMenuAsPrimaryAction = true
            button.configuration?.cornerStyle = .capsule
            button.configuration?.buttonSize = .small
            // An open menu is the user deciding: the card waits for it.
            button.addAction(UIAction { [weak self] _ in self?.closing?.cancel() }, for: .menuActionTriggered)
            buttons.addArrangedSubview(button)
        }
        undoButton.configuration?.title = "Undo"
        undoButton.configuration?.buttonSize = .small
        undoButton.addAction(UIAction { [weak self] _ in self?.undo() }, for: .primaryActionTriggered)
        buttons.addArrangedSubview(undoButton)

        let stack = UIStackView(arrangedSubviews: [spinner, label, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
        ])
        // A tap next to the card closes it; the share is saved by then.
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:))))

        Task { await save() }
    }

    @objc private func tappedOutside(_ tap: UITapGestureRecognizer) {
        guard entry != nil, !card.frame.contains(tap.location(in: view)) else { return }
        close()
    }

    // MARK: Saving

    private func save() async {
        var entry = ShareInbox.Entry()
        var title: String?
        do {
            let folder = try ShareInbox.folder(for: entry.id)
            for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
                title = title ?? item.attributedTitle?.string ?? item.attributedContentText?.string
                for provider in item.attachments ?? [] {
                    await take(provider, into: &entry, folder: folder)
                }
            }
            // A text that is nothing but a link is a link.
            if entry.url == nil, entry.files.isEmpty, let text = entry.text, let link = Self.onlyLink(in: text) {
                entry.url = link
                entry.text = nil
            }
            // A page shared with its address: the text next to it is the title or a quote, not a note of its own.
            if entry.url != nil, entry.files.isEmpty { entry.text = nil }
            guard !entry.isEmpty else {
                ShareInbox.remove(entry.id)
                return fail("Nothing to save")
            }
            // The title is only useful when it is not the address or the text itself.
            let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.title = clean.flatMap { $0.isEmpty || $0.hasPrefix("http") || $0 == entry.text ? nil : String($0.prefix(300)) }
            try ShareInbox.add(entry)
            self.entry = entry
            showSaved()
        } catch {
            ShareInbox.remove(entry.id)
            fail("Could not save")
        }
    }

    private func take(_ provider: NSItemProvider, into entry: inout ShareInbox.Entry, folder: URL) async {
        // Files first: a file is a URL too.
        let fileTypes: [(UTType, ShareInbox.File.Kind)] = [(.pdf, .pdf), (.image, .image), (.audio, .audio), (.movie, .audio)]
        for (type, kind) in fileTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let file = await copy(provider, type: type, kind: kind, folder: folder) { entry.files.append(file) }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let file = await copy(provider, type: .data, kind: .file, folder: folder) { entry.files.append(file) }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if entry.url == nil, let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                let url = (item as? URL) ?? ((item as? NSURL) as URL?)
                if let url, !url.isFileURL { entry.url = url.absoluteString }
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.text = [entry.text, text].compactMap { $0 }.joined(separator: "\n\n")
            }
            return
        }
        // Anything else that is a file of some kind (a document from Files, a contact card, …).
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           let file = await copy(provider, type: .data, kind: .file, folder: folder) {
            entry.files.append(file)
        }
    }

    /// Copies the shared file next to the entry, without reading it into memory (the extension has little of it).
    private func copy(_ provider: NSItemProvider, type: UTType, kind: ShareInbox.File.Kind, folder: URL) async -> ShareInbox.File? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                // The file is only there until this block returns.
                var ext = url.pathExtension.lowercased()
                if ext.isEmpty { ext = type.preferredFilenameExtension ?? "" }
                let stored = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
                do {
                    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(stored))
                    let name = provider.suggestedName.map { name in
                        (name as NSString).pathExtension.isEmpty && !ext.isEmpty ? name + "." + ext : name
                    } ?? url.lastPathComponent
                    // A document is a PDF or an image whatever it was offered as.
                    var kind = kind
                    if kind == .file, let real = UTType(filenameExtension: ext) {
                        if real.conforms(to: .pdf) { kind = .pdf } else if real.conforms(to: .image) { kind = .image }
                        else if real.conforms(to: .audio) || real.conforms(to: .movie) { kind = .audio }
                    }
                    continuation.resume(returning: ShareInbox.File(stored: stored, name: name, kind: kind))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The address when `text` is a single link and nothing else.
    private static func onlyLink(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range), match.range == range,
              let url = match.url, url.scheme?.hasPrefix("http") == true else { return nil }
        return url.absoluteString
    }

    // MARK: The card

    private func showSaved() {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = "✓  Saved to Porridge"
        buttons.isHidden = false
        updateButtons()
        closeSoon(after: 2.5)
    }

    private func updateButtons() {
        guard let entry else { return }
        let projects = ShareInbox.projects()
        bucketButton.isHidden = projects.isEmpty
        let chosen = projects.first { $0.id == entry.projectID }
        bucketButton.configuration?.title = chosen?.name ?? "Bucket"
        bucketButton.configuration?.image = UIImage(systemName: "folder")
        bucketButton.configuration?.imagePadding = 4
        bucketButton.menu = UIMenu(children: [
            UIAction(title: "Inbox", image: UIImage(systemName: "tray"), state: chosen == nil ? .on : .off) { [weak self] _ in
                self?.change { $0.projectID = nil }
            },
        ] + projects.map { project in
            UIAction(title: project.name, state: project.id == entry.projectID ? .on : .off) { [weak self] _ in
                self?.change { $0.projectID = project.id }
            }
        })

    }

    private func change(_ edit: (inout ShareInbox.Entry) -> Void) {
        guard var entry else { return }
        edit(&entry)
        // The app (on an iPad next to the sheet) has saved the share already: nothing to change any more.
        guard (try? ShareInbox.update(entry)) == true else { return showAlreadySaved() }
        self.entry = entry
        updateButtons()
        closeSoon(after: 1.2)
    }

    /// The app took the share in while the card was open: it is saved as it was, the buttons go.
    private func showAlreadySaved() {
        label.text = "✓  Saved to Porridge"
        buttons.isHidden = true
        closeSoon(after: 1.2)
    }

    private func undo() {
        closing?.cancel()
        if let entry, !ShareInbox.isPending(entry.id) { return showAlreadySaved() }
        if let entry { ShareInbox.remove(entry.id) }
        entry = nil
        buttons.isHidden = true
        label.text = "Not saved"
        closeSoon(after: 0.7)
    }

    private func fail(_ message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = message
        closeSoon(after: 1.6)
    }

    private func closeSoon(after seconds: Double) {
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        closing?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
