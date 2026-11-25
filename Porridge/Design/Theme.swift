import SwiftUI
import UIKit

extension Color {
    static let brandSky = Color("BrandSky")
    static let brandNavy = Color("BrandNavy")
    /// Saved links.
    static let brandLink = Color("BrandLink")
    /// Projects: violet.
    static let brandProject = Color("BrandProject")
    /// Check boxes in summaries: a fresh green next to the sky blue.
    static let brandTask = Color("BrandTask")

    // Sky, orange and green are too light for text and symbols on a white page: these are their readable forms.
    static let brandSkyText = Color("BrandSkyText")
    static let brandLinkText = Color("BrandLinkText")
    static let brandTaskText = Color("BrandTaskText")
    static let brandDangerText = Color("BrandDangerText")
    /// Violet as text: bowl names, "✦ Bowl", who changed what.
    static let brandProjectText = Color("BrandProjectText")
    /// The fill of the one undo toast (navy, lighter in dark mode); its text is white.
    static let toastFill = Color("ToastFill")

    /// Symbols and text on a full fill of sky, orange or green.
    static let brandOnFill = Color("BrandOnFill")
    /// Symbols and text on a full fill of navy or the accent color, which turn light in dark mode.
    static let brandOnNavy = Color("BrandOnNavy")

    /// This color as text or a symbol on the page.
    var readable: Color {
        if self == .brandSky { return .brandSkyText }
        if self == .brandLink { return .brandLinkText }
        if self == .brandTask { return .brandTaskText }
        if self == .red { return .brandDangerText }
        return self
    }

    /// What goes on top of a full fill of this color.
    var onFill: Color {
        if self == .brandSky || self == .brandLink || self == .brandTask { return .brandOnFill }
        if self == .brandNavy || self == .accentColor { return .brandOnNavy }
        return .white
    }

    // System surfaces, the same idea on iOS and macOS.
    static var appBackground: Color { Color(.systemBackground) }
    static var appSecondaryBackground: Color { Color(.secondarySystemBackground) }
    static var appGroupedBackground: Color { Color(.systemGroupedBackground) }

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

/// The app's look, after Things 3: white pages, hairline separators, cards that float on a soft shadow.
/// `DESIGN.md` says what each color stands for.
enum Look {
    static let cardRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 12
    /// Hairline around surfaces where there is no shadow to separate them (dark mode, fields).
    static let outline: CGFloat = 1
    static let thinOutline: CGFloat = 1
    static let hairline = Color.primary.opacity(0.1)
    /// Space below the bar of a list; the content below starts without its own top padding.
    static let headerGap: CGFloat = 16
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
    var foreground: Color = .brandNavy
    var horizontalPadding: CGFloat = 24
    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? 1 : 0.45)
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
            .foregroundStyle(Color.brandOnFill)
            .frame(width: size, height: size)
            .background(Color.brandSky, in: Circle())
            .shadow(color: Color.brandSky.opacity(0.35), radius: 6, y: 3)
    }
}

/// Rounded square in front of a list row (the place of the checkbox in Things): its color says what the entry is.
/// The design's token (stage 7): 30 pt, corner 8, a 15 % wash of the kind's color without a border, the symbol in
/// the readable value of the color; it grows a little with the text size.
struct ThingsRowIcon: View {
    /// Where the separator starts: icon + spacing.
    static let inset: CGFloat = 30 + 12

    let systemImage: String
    var tint: Color = .brandSky
    /// A pinned entry wears a pin on the icon's border, top right.
    var isPinned = false
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(tint.readable)
            .frame(width: min(size, 42), height: min(size, 42))
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.brandOnNavy)
                        .frame(width: 18, height: 18)
                        .background(Color.brandNavy, in: Circle())
                        .overlay(Circle().strokeBorder(Color.appBackground, lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Pinned")
                }
            }
    }
}

extension View {
    /// The header of the next section brings its own line: the last row of a section draws none.
    func lastInSection(_ isLast: Bool) -> some View {
        listRowSeparator(isLast ? .hidden : .automatic, edges: .bottom)
    }
}

/// Things: bold title over a hairline, no symbol. The first one sits right under the bar (the gap comes from
/// there, `Look.headerGap`); later ones keep a little more air than the list gives between sections.
struct ListHeader: View {
    let title: String
    var count: Int?
    var tint: Color = .brandSky
    var isFirst = false
    /// A quiet word after the title ("by Last Change").
    var detail: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The largest text sizes: the quiet word goes under the title instead of squeezing it.
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))) {
                Text(title)
                if let count {
                    Text("\(count)").foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(tint.readable)
            Rectangle().fill(Look.hairline).frame(height: 0.5)
        }
        .padding(.top, isFirst ? 0 : 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
        .textCase(nil)
    }
}

/// A section of a card list whose header stays pinned at the top while its rows scroll, as before, except with the
/// largest text sizes: there the header (two lines and more) scrolls along as the section's first row, since a
/// pinned header that tall lies over the rows under it and takes their taps.
struct CardSection<Content: View, Header: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                content
            }
        } else {
            Section {
                content
            } header: {
                header
            }
        }
    }
}

/// A section header that can be tapped, with a chevron at its end: unfolds its section or leads to a page.
struct ListHeaderButton: View {
    let title: String
    var count: Int?
    var tint: Color = .brandSky
    var isFirst = false
    /// Unfolded: the chevron points down.
    var isOpen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ListHeader(title: title, count: count, tint: tint, isFirst: isFirst)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .padding(.bottom, 9)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
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
        // For VoiceOver one thing to press, not a symbol, two texts and a nameless button.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
    /// Makes the title a button (Today: back to today from another day), with the hint VoiceOver reads for it.
    var onTitleTap: (() -> Void)?
    var titleHint = ""
    @ViewBuilder var actions: Actions

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var squareSize: CGFloat = 34
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The pills take the screen's color too; the sky screens keep the accent color for contrast.
    private var buttonTint: Color? { tint == .brandSky ? nil : tint.readable }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // The largest text sizes: the pills keep their row, the title gets one of its own below them and may
                // take two lines, so neither is cut to "Meeti…" or shrinks the pills.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        backButton
                        Spacer(minLength: 8)
                        pills
                    }
                    titleView(lineLimit: 2)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    backButton
                    titleView(lineLimit: 1)
                    Spacer(minLength: 8)
                    pills
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var backButton: some View {
        if let onBack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .foregroundStyle(buttonTint ?? .accentColor)
            }
            .buttonStyle(ChromePillButtonStyle(tint: buttonTint))
        }
    }

    private func titleView(lineLimit: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(tint.onFill)
                .frame(width: min(squareSize, 44), height: min(squareSize, 44))
                .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title)
                .font(.system(size: min(titleSize, 52), weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                // "Meeting" beside three pills on a 390 pt iPhone needs a little more than 70 %.
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onTitleTap == nil ? .isHeader : [.isHeader, .isButton])
        .accessibilityHint(onTitleTap == nil ? "" : titleHint)
        .contentShape(Rectangle())
        .onTapGesture { onTitleTap?() }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            actions
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.medium))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .foregroundStyle(buttonTint ?? .accentColor)
        .tint(buttonTint ?? .accentColor)
        .buttonStyle(ChromePillButtonStyle(tint: buttonTint))
        .menuStyle(.button)
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
        ChromePill(configuration: configuration, fill: fill, tint: tint)
    }
}

/// The pill itself: dimmed while its button is disabled (Select in an empty Inbox).
private struct ChromePill: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color?
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    /// 44 × 36; 56 × 46 with the largest text sizes (the symbol grows up to accessibility 1).
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        configuration.label
            .foregroundStyle(fill.map { AnyShapeStyle($0.onFill) } ?? AnyShapeStyle(tint ?? .accentColor))
            .frame(minWidth: typeSize.isAccessibilitySize ? 56 : 44, minHeight: typeSize.isAccessibilitySize ? 46 : 36)
            .background(
                fill.map { $0.opacity(configuration.isPressed ? 0.8 : 1) } ?? (tint ?? .brandSky).opacity(configuration.isPressed ? 0.26 : 0.14),
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Options sharing the full width: the system's segmented control. Its text does not grow with the largest text
/// sizes, so there the options are capsules that grow and wrap onto more lines.
struct TabSwitcher<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options, id: \.value) { option in
                    let chosen = option.value == selection
                    Button {
                        withAnimation(.snappy) { selection = option.value }
                    } label: {
                        Text(option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(chosen ? Color.brandOnNavy : .primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(chosen ? AnyShapeStyle(Color.brandNavy) : AnyShapeStyle(.quaternary), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? [.isSelected] : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("View", selection: $selection.animation(.snappy)) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

/// Round floating action button (the "Magic Plus" of Things): sky fill, white glyph, soft colored shadow.
struct FloatingActionButton: View {
    let systemImage: String
    let label: String
    var fill: Color = .brandSky
    /// Nil: what suits the fill.
    var foreground: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(foreground ?? fill.onFill)
                .frame(width: 58, height: 58)
        }
        .buttonStyle(FloatingActionButtonStyle(fill: fill))
        .accessibilityLabel(label)
    }
}

extension View {
    /// The round shape of the floating buttons.
    func floatingCircle(fill: Color, pressed: Bool = false) -> some View {
        self
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(Look.hairline, lineWidth: 0.5))
            .shadow(color: (fill == .brandSky ? fill : Color.black).opacity(pressed ? 0.12 : 0.22), radius: pressed ? 4 : 10, y: pressed ? 2 : 5)
    }
}

private struct FloatingActionButtonStyle: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .floatingCircle(fill: fill, pressed: pressed)
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
        .foregroundStyle(color.readable)
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
        UIPasteboard.general.string = text
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

/// The system setting Reduce Motion: what slides elsewhere only fades in then.
enum Motion {
    static var isReduced: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    static func slide(_ transition: AnyTransition) -> AnyTransition {
        isReduced ? .opacity : transition
    }
}

// MARK: - Platform differences

extension View {
    /// Small centered navigation title (iOS); the Mac has no navigation bar title mode.
    func inlineNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    func urlFieldStyle() -> some View {
        keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    func secretFieldStyle() -> some View {
        textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    func plainFieldStyle() -> some View {
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    /// Full screen on iOS, a sheet on the Mac.
    func fullScreenCoverOrSheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented, content: content)
    }
}

// MARK: - Keyboard

extension View {

    /// A "Done" pill in glass above the keyboard, at the right. Content scrolls underneath it. (iOS)
    func keyboardDoneBar(isShown: Bool, action: @escaping () -> Void) -> some View {
        overlay(alignment: .bottomTrailing) {
            if isShown {
                Button("Done", action: action)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .modifier(BarBackground())
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
                    .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity)))
            }
        }
    }

}

/// Capsule of glass for the bars above the keyboard.
struct BarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

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
