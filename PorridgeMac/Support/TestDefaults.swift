import Foundation
import ObjectiveC

/// Test runs of the Mac app (`PORRIDGE_TEST_DATA=<folder>`, Debug only) keep their settings apart from the owner's.
///
/// The Debug app is not sandboxed, so without this every run would read and write
/// `~/Library/Preferences/de.letzgo.porridge.plist`: recent searches, window frames, the default model, the MCP token.
/// With test data, `UserDefaults.standard` (and with it `@AppStorage` and AppKit's own autosaves) is a suite stored in the test folder (`<folder>/Preferences.plist`), new for every new folder. Launch arguments
/// (`-key value`) still win as before. Secrets stay in memory (`Keychain`), so no cloud model has a key and none is
/// asked. Normal runs are unchanged.
enum TestDefaults {
    #if DEBUG
    nonisolated(unsafe) private(set) static var suite: UserDefaults?
    #endif

    /// Whether this run keeps its settings in the test folder.
    static var isActive: Bool {
        #if DEBUG
        suite != nil
        #else
        false
        #endif
    }

    /// Called first thing in `main`, before anything reads a default.
    static func install() {
        #if DEBUG
        guard suite == nil, let folder = DataLocation.testFolder,
              let defaults = UserDefaults(suiteName: folder.appendingPathComponent("Preferences").path) else { return }
        // A new test folder starts past the onboarding (a test of it passes `-onboardingDone NO`) and on the device's
        // own model: the stored default stays local unless a test chooses otherwise.
        if defaults.object(forKey: AppSettings.onboardingDoneKey) == nil {
            defaults.set(true, forKey: AppSettings.onboardingDoneKey)
        }
        if defaults.object(forKey: AppSettings.billingKey) == nil {
            defaults.set(SummaryBilling.local.rawValue, forKey: AppSettings.billingKey)
        }
        suite = defaults
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return }
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(method, imp_implementationWithBlock(block))
        #endif
    }
}
