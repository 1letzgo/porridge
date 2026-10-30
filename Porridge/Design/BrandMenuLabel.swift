import SwiftUI

/// Icon of a `Menu` in a toolbar: the standard system look.
struct BrandMenuLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
    }
}
