import XCTest
@testable import Porridge

final class AppSettingsTests: XCTestCase {
    func testNewNotesDoNotRecordByDefault() {
        AppSettings.registerDefaults()
        let defaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(defaults[AppSettings.recordsNewNotesKey] as? Bool, false)
    }
}
