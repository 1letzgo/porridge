import UIKit
import XCTest
@testable import Porridge

/// The palette against the limits of the Human Interface Guidelines: 4.5:1 for text, 3:1 for bold text and symbols.
final class BrandContrastTests: XCTestCase {
    private func color(_ name: String, dark: Bool, highContrast: Bool = false) throws -> UIColor {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: highContrast ? .high : .normal),
        ])
        let found = try XCTUnwrap(UIColor(named: name, in: .main, compatibleWith: traits), "\(name) missing")
        return found.resolvedColor(with: traits)
    }

    private func ratio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testTextColorsOnThePage() throws {
        for dark in [false, true] {
            let page: UIColor = dark ? .black : .white
            for name in ["BrandSkyText", "BrandLinkText", "BrandDangerText", "BrandNavy", "AccentColor"] {
                let value = ratio(try color(name, dark: dark), page)
                XCTAssertGreaterThanOrEqual(value, 4.5, "\(name), dark: \(dark)")
            }
            for name in ["BrandTaskText", "BrandProject"] {
                let value = ratio(try color(name, dark: dark), page)
                XCTAssertGreaterThanOrEqual(value, dark ? 4.5 : 3, "\(name), dark: \(dark)")
            }
        }
    }

    func testSymbolsOnFullFills() throws {
        for dark in [false, true] {
            for fill in ["BrandSky", "BrandLink", "BrandTask"] {
                XCTAssertGreaterThanOrEqual(ratio(try color("BrandOnFill", dark: dark), try color(fill, dark: dark)), 3, fill)
            }
            for fill in ["BrandNavy", "AccentColor"] {
                XCTAssertGreaterThanOrEqual(ratio(try color("BrandOnNavy", dark: dark), try color(fill, dark: dark)), 3, fill)
            }
            XCTAssertGreaterThanOrEqual(ratio(.white, try color("BrandProject", dark: dark)), 3, "white on violet")
        }
    }

    /// Violet as text (bowl names, activity) on the page and on a card, normal and Increase Contrast.
    func testProjectTextOnPageAndCard() throws {
        for dark in [false, true] {
            // The page, and a card on it (`secondarySystemGroupedBackground`: white in light mode, #1C1C1E in dark).
            let surfaces: [UIColor] = dark ? [.black, UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)] : [.white]
            for highContrast in [false, true] {
                let text = try color("BrandProjectText", dark: dark, highContrast: highContrast)
                for surface in surfaces {
                    XCTAssertGreaterThanOrEqual(ratio(text, surface), 4.5, "BrandProjectText, dark: \(dark), high contrast: \(highContrast)")
                }
            }
        }
        XCTAssertGreaterThan(
            ratio(try color("BrandProjectText", dark: false, highContrast: true), .white),
            ratio(try color("BrandProjectText", dark: false), .white)
        )
    }

    /// The undo toast: white text and symbols on its fill, the "Undo" capsule (16 % white) included.
    func testWhiteOnToastFill() throws {
        for dark in [false, true] {
            for highContrast in [false, true] {
                let fill = try color("ToastFill", dark: dark, highContrast: highContrast)
                XCTAssertGreaterThanOrEqual(ratio(.white, fill), 4.5, "white on ToastFill, dark: \(dark), high contrast: \(highContrast)")
                XCTAssertGreaterThanOrEqual(ratio(.white, blend(.white, 0.16, over: fill)), 4.5, "Undo capsule, dark: \(dark)")
            }
        }
    }

    /// `top` at `alpha` over `bottom`.
    private func blend(_ top: UIColor, _ alpha: CGFloat, over bottom: UIColor) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        top.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        bottom.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 * alpha + r2 * (1 - alpha), green: g1 * alpha + g2 * (1 - alpha), blue: b1 * alpha + b2 * (1 - alpha), alpha: 1)
    }

    func testIncreaseContrastIsStrongerThanNormal() throws {
        for name in ["BrandSkyText", "BrandLinkText", "BrandTaskText", "BrandDangerText"] {
            let normal = ratio(try color(name, dark: false), .white)
            let strong = ratio(try color(name, dark: false, highContrast: true), .white)
            XCTAssertGreaterThan(strong, normal, name)
        }
    }
}
