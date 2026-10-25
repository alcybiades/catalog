import SwiftUI

struct WikiImage: Hashable, Sendable {
    var url: URL
    var width: Double
    var height: Double
    /// "File:Name.jpg", used to avoid showing the lead image twice.
    var file: String?
    /// The source file's pixel width, when known.
    var originalWidth: Double? = nil

    var aspectRatio: Double { width > 0 && height > 0 ? width / height : 4.0 / 3.0 }
}

struct ListItem: Identifiable, Sendable {
    let id: Int
    var level: Int
    var marker: String
    var text: AttributedString
}

struct TableCell: Sendable {
    var text: AttributedString
    var isHeader: Bool
}

struct TableData: Sendable {
    var caption: AttributedString?
    var rows: [[TableCell]]
}

enum InfoRow: Sendable {
    case header(String)
    /// Bold centered lines under the title, such as a period's dates.
    case subheader(AttributedString)
    /// Where the subject sits in a sequence: "← Pliocene · Stone Age · Bronze Age →".
    case succession(previous: AttributedString?, current: String?, next: AttributedString?)
    case pair(label: String, value: AttributedString)
    case text(AttributedString)
    case image([WikiImage], caption: AttributedString?)
    case map(LocationMap, caption: AttributedString?)
    /// A taxobox's "Temporal range" bar.
    case range(GeologicRange)
    case timeline(GraphicalTimeline)
}

enum BlockKind: Sendable {
    case heading(level: Int, text: String, anchor: String)
    case paragraph(AttributedString)
    /// Hatnotes ("For other uses, see…").
    case note(AttributedString)
    case list([ListItem])
    case quote(AttributedString)
    case figure([WikiImage], caption: AttributedString?)
    case table(TableData)
    case math(String)
    case preformatted(String)
    case timeline(GraphicalTimeline)
    case cladogram(CladeNode)
    case map(LocationMap, caption: AttributedString?)
}

struct Block: Identifiable, Sendable {
    let id: Int
    var kind: BlockKind
}

struct ArticleSection: Identifiable, Hashable, Sendable {
    /// The heading's anchor, also the scroll target.
    var id: String
    var title: String
    var level: Int
}

struct Article: Sendable {
    var title: String
    var summary: String?
    var url: URL
    var leadImage: WikiImage?
    var leadCaption: AttributedString?
    var infobox: [InfoRow]
    var blocks: [Block]
    var sections: [ArticleSection]
    /// The article as Markdown-ish plain text, for the assistant.
    var plainText: String
}

/// A request to show an article; `id` keeps two visits to the same title distinct.
struct ArticleRoute: Hashable {
    let id = UUID()
    var query: String
    var fragment: String?
    var isRandom = false
}
