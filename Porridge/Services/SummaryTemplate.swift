import Foundation

/// What a meeting summary looks at and which sections it has. Whatever the template, the summary starts with its
/// summary section and ends with the tasks and tags, because the task list and the tag field read those.
struct SummaryTemplate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Told to the model in its own words; empty for a plain summary.
    var focus: String
    /// The sections between summary and tasks, nil for key points and decisions.
    var sections: [String]?

    static let general = SummaryTemplate(id: "general", name: "General", focus: "", sections: nil)

    static let builtIn: [SummaryTemplate] = [
        general,
        SummaryTemplate(
            id: "oneOnOne", name: "One-on-One",
            focus: "This is a one-on-one conversation. Pay attention to how the person is doing, feedback in both directions, goals and what was agreed.",
            sections: ["Feedback", "Goals", "Agreements"]
        ),
        SummaryTemplate(
            id: "customer", name: "Customer Call",
            focus: "This is a call with a customer. Pay attention to what the customer needs, objections and open questions, what was promised and the next steps.",
            sections: ["Customer Needs", "Objections and Questions", "Commitments"]
        ),
        SummaryTemplate(
            id: "lecture", name: "Lecture",
            focus: "This is a lecture or talk. Pay attention to the content: concepts, definitions, examples and how they connect, not to who said what.",
            sections: ["Key Concepts", "Examples"]
        ),
    ]

    static var custom: [SummaryTemplate] {
        get {
            guard let text = UserDefaults.standard.string(forKey: AppSettings.customTemplatesKey),
                  let list = try? JSONDecoder().decode([SummaryTemplate].self, from: Data(text.utf8)) else { return [] }
            return list
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: AppSettings.customTemplatesKey)
        }
    }

    static var all: [SummaryTemplate] { builtIn + custom }
}
