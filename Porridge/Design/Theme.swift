import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    static let brandSky = Color("BrandSky")
    static let brandNavy = Color("BrandNavy")
    /// Saved links.
    static let brandLink = Color(red: 0.98, green: 0.56, blue: 0.14)
    /// Tasks: a fresh green next to the sky blue.
    static let brandTask = Color(red: 0.16, green: 0.74, blue: 0.50)
    /// Chat.
    static let brandChat = Color(red: 0.90, green: 0.25, blue: 0.24)

    // System surfaces, the same idea on iOS and macOS.
    #if canImport(UIKit)
    static var appBackground: Color { Color(.systemBackground) }
    static var appSecondaryBackground: Color { Color(.secondarySystemBackground) }
    static var appGroupedBackground: Color { Color(.systemGroupedBackground) }
    #else
    static var appBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var appSecondaryBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var appGroupedBackground: Color { Color(nsColor: .windowBackgroundColor) }
    #endif

    private static let speakerPalette: [Color] = [
        .brandSky,
        Color(red: 0.96, green: 0.55, blue: 0.20),
        Color(red: 0.36, green: 0.72, blue: 0.36),
        Color(red: 0.62, green: 0.42, blue: 0.86),
        Color(red: 0.93, green: 0.38, blue: 0.55),
        Color(red: 0.20, green: 0.66, blue: 0.66),
    ]

    static func speaker(_ index: Int) -> Color {
        speakerPalette[abs(index) % speakerPalette.count]
    }
}

/// The app's look, after Things 3: white pages, hairline separators, cards that float on a soft shadow,
/// sky blue only for what you can act on (the plus button, selection, toggles).
enum Look {
    static let cardRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 12
    /// Hairline around surfaces where there is no shadow to separate them (dark mode, fields).
    static let outline: CGFloat = 1
    static let thinOutline: CGFloat = 1
    static let hairline = Color.primary.opacity(0.1)
    /// Space above and below the tabs of the list header; the content below starts without its own top padding.
    static let headerGap: CGFloat = 12
}

extension View {
    /// The app's surface: a filled shape that floats on a soft two-layer shadow (a hairline in dark mode,
    /// where shadows disappear). `depth` and `lineWidth` are kept for call sites; the look has no outline.
    func brandSurface<S: InsettableShape>(
        _ shape: S, fill: Color = Color.appBackground, pressed: Bool = false,
        depth: CGFloat = 4, lineWidth: CGFloat? = nil
    ) -> some View {
        background {
            shape.fill(Color.appBackground)
                // Tinted fills are translucent: keep an opaque base.
                .overlay(shape.fill(fill))
                .overlay(shape.strokeBorder(Look.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(pressed ? 0.04 : 0.06), radius: 3, y: 1)
                .shadow(color: Color.brandNavy.opacity(pressed ? 0.06 : 0.12), radius: pressed ? 8 : 18, y: pressed ? 4 : 10)
        }
    }
}

/// Main button: a tinted rounded rectangle (sky wash, navy label), like a native bordered button.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color = .brandSky
    var foreground: Color = .accentColor
    var horizontalPadding: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(fill.opacity(pressed ? 0.26 : 0.16), in: RoundedRectangle(cornerRadius: Look.buttonRadius, style: .continuous))
            .animation(.snappy(duration: 0.12), value: pressed)
    }
}

/// Card that floats on the page.
private struct ChunkyCard: ViewModifier {
    var fill: Color?
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandSurface(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous), fill: fill ?? Color.appBackground)
    }
}

extension View {
    /// Wraps the content in a floating card.
    func chunkyCard(fill: Color? = nil, padding: CGFloat = 16) -> some View {
        modifier(ChunkyCard(fill: fill, padding: padding))
    }

    /// Flat tinted panel for notices inside a page (status, errors): no shadow, so nothing gets cut off
    /// at the edges of a scroll view.
    func flatPanel(_ tint: Color = .brandSky, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
    }

    /// Row of a plain list: hairline separator from the text on, no row background.
    func cardListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
            .listRowBackground(Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + ThingsRowIcon.inset }
    }

    /// Plain list on the white page.
    func cardList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .contentMargins(.top, 0, for: .scrollContent)
            .environment(\.defaultMinListHeaderHeight, 0)
    }

    /// Small capsule label (speaker chips): a wash of the color.
    func chunkyPill(fill: Color) -> some View {
        background(fill.opacity(0.18), in: Capsule())
    }

    /// Round icon button background (player): sky circle with a white glyph.
    func chunkyCircle(size: CGFloat) -> some View {
        self
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.brandSky, in: Circle())
            .shadow(color: Color.brandSky.opacity(0.35), radius: 6, y: 3)
    }
}

/// Rounded square in front of a list row (the place of the checkbox in Things): its color says what the entry is.
struct ThingsRowIcon: View {
    /// Where the separator starts: row padding + icon + spacing.
    static let inset: CGFloat = 22 + 12

    let systemImage: String
    var tint: Color = .brandSky

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1.5))
    }
}

/// A list row that opens a detail.
struct ListRowLink<Content: View>: View {
    let value: UUID
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            NavigationLink(value: value) { EmptyView() }.opacity(0)
            content
        }
        .cardListRow()
    }
}

/// The app's own bar in place of the system navigation bar (iOS), as in Things: an optional back pill,
/// the colored square with the screen's symbol and the big bold title on the left, actions as pills on the right.
struct ChromeBar<Actions: View>: View {
    let title: String
    let systemImage: String
    /// Color of the square behind the symbol.
    var tint: Color = .brandSky
    /// Shows a back pill in front of the title.
    var onBack: (() -> Void)?
    @ViewBuilder var actions: Actions

    /// The pills take the screen's color too; the sky screens keep the accent color for contrast.
    private var buttonTint: Color? { tint == .brandSky ? nil : tint }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(buttonTint ?? .accentColor)
                }
                .buttonStyle(ChromePillButtonStyle(tint: buttonTint))
            }
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                actions
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(buttonTint ?? .accentColor)
            .tint(buttonTint ?? .accentColor)
            .buttonStyle(ChromePillButtonStyle(tint: buttonTint))
            .menuStyle(.button)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

extension ChromeBar where Actions == EmptyView {
    init(title: String, systemImage: String, onBack: (() -> Void)? = nil) {
        self.init(title: title, systemImage: systemImage, onBack: onBack) { EmptyView() }
    }
}

/// Button of the custom bar: the icon on a light pill of `tint` (sky with the accent color when nil), or white
/// on a full pill of `fill` when the button stands for something that is switched on (an active filter).
struct ChromePillButtonStyle: ButtonStyle {
    var fill: Color?
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(fill == nil ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(.white))
            .frame(width: 44, height: 36)
            .background(
                fill.map { $0.opacity(configuration.isPressed ? 0.8 : 1) } ?? (tint ?? .brandSky).opacity(configuration.isPressed ? 0.26 : 0.14),
                in: Capsule()
            )
            .contentShape(Capsule())
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Options as quiet text tabs sharing the full width; the selected one sits on a light sky pill.
/// The switcher of the start page (Timeline / Chat / Search) and of the note views.
struct TabSwitcher<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// Color of a selected tab; nil keeps the accent color.
    var tint: (Value) -> Color? = { _ in nil }

    var body: some View {
        #if os(macOS)
        // The Mac has its own control for this: a segmented picker.
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        #else
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                tab(option.value, option.title)
            }
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    #if os(iOS)
    private func tab(_ value: Value, _ label: String) -> some View {
        let selected = selection == value
        let color = tint(value)
        return Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? color ?? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(selected ? (color ?? Color.brandSky).opacity(0.14) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #endif
}

/// Round floating action button (the "Magic Plus" of Things): sky fill, white glyph, soft colored shadow.
struct FloatingActionButton: View {
    let systemImage: String
    let label: String
    var fill: Color = .brandSky
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: 58, height: 58)
        }
        .buttonStyle(FloatingActionButtonStyle(fill: fill))
        .accessibilityLabel(label)
    }
}

private struct FloatingActionButtonStyle: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(Look.hairline, lineWidth: 0.5))
            .shadow(color: (fill == .brandSky ? fill : Color.black).opacity(pressed ? 0.12 : 0.22), radius: pressed ? 4 : 10, y: pressed ? 2 : 5)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.12), value: pressed)
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var spinning = false

    var body: some View {
        HStack(spacing: 4) {
            if spinning {
                ProgressView().controlSize(.mini)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    /// Kept for call sites; the bowl from the app icon is shown instead.
    var systemImage = "tray"

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image("Bowl")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } description: {
            Text(message)
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension View {
    /// Small centered navigation title (sheets and details).
    func brandNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .inlineNavigationTitle()
    }
}

extension View {
    /// Toolbar button in the standard system look (kept as one place to change it).
    func brandToolbarButton() -> some View {
        self
    }
}

/// Toolbar item in the standard system look.
struct BrandToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .primaryAction
    @ViewBuilder var content: Content

    var body: some ToolbarContent {
        ToolbarItem(placement: placement) { content }
    }
}

// MARK: - Platform differences

extension View {
    /// Small centered navigation title (iOS); the Mac has no navigation bar title mode.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func urlFieldStyle() -> some View {
        #if os(iOS)
        keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        autocorrectionDisabled()
        #endif
    }

    func secretFieldStyle() -> some View {
        #if os(iOS)
        textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        autocorrectionDisabled()
        #endif
    }

    func plainFieldStyle() -> some View {
        #if os(iOS)
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// Full screen on iOS, a sheet on the Mac.
    func fullScreenCoverOrSheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) {
            content().frame(minWidth: 520, minHeight: 680)
        }
        #endif
    }
}

// MARK: - Keyboard

extension View {
    /// A "Done" button above the keyboard. `action` takes the focus away from the field (`focused = false`),
    /// which is what closes the keyboard.
    func keyboardDoneButton(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: action)
                    .fontWeight(.semibold)
            }
        }
        #else
        self
        #endif
    }

    /// A "Done" pill in glass above the keyboard, at the right. Content scrolls underneath it. (iOS)
    func keyboardDoneBar(isShown: Bool, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        overlay(alignment: .bottomTrailing) {
            if isShown {
                Button("Done", action: action)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .modifier(BarBackground())
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        #else
        self
        #endif
    }

    /// Dragging a scroll view closes the keyboard (iOS).
    func dismissKeyboardOnScroll() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}

/// Capsule of glass for the bars above the keyboard.
struct BarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

#if os(iOS)
// MARK: - Swipe back

/// Screens with our own bar (ChromeBar) hide the system navigation bar, which also turns off the swipe
/// from the left edge. This keeps it on whenever there is a screen to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
#endif
