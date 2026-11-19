import Foundation

/// The third-party packages and models the app uses, from `Acknowledgements.json` (built by
/// scripts/acknowledgements.py): name, version, license and the full license text.
struct Acknowledgements: Decodable {
    struct Entry: Decodable, Identifiable {
        let name: String
        let version: String
        let license: String
        let url: String
        /// Key into `licenses`: the same text is stored once.
        let text: String

        var id: String { name }
    }

    struct Section: Decodable, Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    let licenses: [String: String]
    let sections: [Section]

    static let bundled: Acknowledgements = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(Acknowledgements.self, from: data)
        else { return Acknowledgements(licenses: [:], sections: []) }
        return list
    }()
}
