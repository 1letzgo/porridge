import AppKit

/// The colors of `DESIGN.md` for AppKit, from the same asset catalog as the iOS app (`Porridge/Resources`).
/// Every kind of thing keeps its color everywhere: in the list icon, its section header and its page.
extension NSColor {
    static let brandSky = NSColor(named: "BrandSky") ?? .systemBlue
    static let brandNavy = NSColor(named: "BrandNavy") ?? .labelColor
    /// Saved links.
    static let brandLink = NSColor(named: "BrandLink") ?? .systemOrange
    /// Bowls: violet.
    static let brandProject = NSColor(named: "BrandProject") ?? .systemPurple
    /// Check boxes in summaries.
    static let brandTask = NSColor(named: "BrandTask") ?? .systemGreen

    // Readable forms of the light colors, as text or a symbol on the page.
    static let brandSkyText = NSColor(named: "BrandSkyText") ?? .systemBlue
    static let brandLinkText = NSColor(named: "BrandLinkText") ?? .systemOrange
    static let brandTaskText = NSColor(named: "BrandTaskText") ?? .systemGreen
    static let brandDangerText = NSColor(named: "BrandDangerText") ?? .systemRed
    /// Violet as text: bowl names, "✦ Bowl", who changed what.
    static let brandProjectText = NSColor(named: "BrandProjectText") ?? .systemPurple
    /// The fill of the one undo toast (navy, lighter in dark mode); its text is white.
    static let toastFill = NSColor(named: "ToastFill") ?? .darkGray

    /// Symbols and text on a full fill of sky, orange or green.
    static let brandOnFill = NSColor(named: "BrandOnFill") ?? .black
    /// Symbols and text on a full fill of navy, which turns light in dark mode.
    static let brandOnNavy = NSColor(named: "BrandOnNavy") ?? .white

    /// This color as text or a symbol on the page.
    var readable: NSColor {
        if self == .brandSky { return .brandSkyText }
        if self == .brandLink { return .brandLinkText }
        if self == .brandTask { return .brandTaskText }
        if self == .systemRed { return .brandDangerText }
        return self
    }

    /// What goes on top of a full fill of this color.
    var onFill: NSColor {
        if self == .brandSky || self == .brandLink || self == .brandTask { return .brandOnFill }
        if self == .brandNavy || self == .controlAccentColor { return .brandOnNavy }
        return .white
    }

    /// Speakers have their own sequence of colors, starting with sky and orange.
    static func speaker(_ index: Int) -> NSColor {
        let palette: [NSColor] = [
            .brandSky,
            NSColor(srgbRed: 0.96, green: 0.55, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.36, green: 0.72, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.42, blue: 0.86, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.38, blue: 0.55, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.66, blue: 0.66, alpha: 1),
        ]
        return palette[abs(index) % palette.count]
    }

    /// A color resolved for the appearance of a view (for layers, which do not follow dynamic colors).
    func resolved(for view: NSView) -> CGColor {
        var result = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { result = self.cgColor }
        return result
    }
}

/// What a note is, for its icon and color: meetings navy, notes sky, links orange, images and files navy.
enum NoteKindStyle {
    /// The shared symbol of the note's kind (`Note.kindSymbol`).
    static func symbol(for note: Note) -> String { note.kindSymbol }

    static func tint(for note: Note) -> NSColor {
        if note.isTodo { return .brandTask }
        return note.isLink ? .brandLink : (note.isRecording || note.isStored ? .brandNavy : .brandSky)
    }

    static func name(for note: Note) -> String { note.kindName }

}

extension NSImage {
    /// An SF Symbol with a weight and size, for buttons and cells.
    /// A name that is no SF Symbol is one of the app's own template images (`BowlPlace`, `BowlPlaceFill`), sized to
    /// the symbol's point size.
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, label: String? = nil) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label) else {
            guard let own = NSImage(named: name)?.copy() as? NSImage else { return NSImage() }
            let height = (size * 1.05).rounded()
            own.size = NSSize(width: (height * own.size.width / max(own.size.height, 1)).rounded(), height: height)
            own.isTemplate = true
            own.accessibilityDescription = label
            return own
        }
        return image.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? image
    }
}
