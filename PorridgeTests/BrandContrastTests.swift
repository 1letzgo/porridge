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

    func testIncreaseContrastIsStrongerThanNormal() throws {
        for name in ["BrandSkyText", "BrandLinkText", "BrandTaskText", "BrandDangerText"] {
            let normal = ratio(try color(name, dark: false), .white)
            let strong = ratio(try color(name, dark: false, highContrast: true), .white)
            XCTAssertGreaterThan(strong, normal, name)
        }
    }
}
