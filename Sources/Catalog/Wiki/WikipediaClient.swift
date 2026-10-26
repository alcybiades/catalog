import Foundation

enum WikiError: LocalizedError {
    case notFound(String)
    case badResponse
    case offline

    var errorDescription: String? {
        switch self {
        case .notFound(let query): "Nothing on Wikipedia matches “\(query)”."
        case .badResponse: "Wikipedia sent back something unexpected."
        case .offline: "Couldn’t reach Wikipedia. Check your connection and try again."
        }
    }
}

/// Fetches and assembles articles from the English Wikipedia API.
enum WikipediaClient {
    static let api = URL(string: "https://en.wikipedia.org/w/api.php")!
    static let userAgent = "Encyclopedia/1.0 (native Wikipedia reader for iOS and macOS)"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Api-User-Agent": userAgent]
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: Public

    /// "I'm feeling lucky": the exact title if it exists, otherwise the best search hit.
    static func article(for query: String) async throws -> Article {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WikiError.notFound(query) }
        do {
            return try await load(title: trimmed)
        } catch WikiError.notFound {
            guard let best = try await bestMatch(for: trimmed) else { throw WikiError.notFound(trimmed) }
            return try await load(title: best)
        }
    }

    /// Article titles starting with `prefix`, for the search field.
    static func suggestions(for prefix: String) async throws -> [String] {
        let json = try await get([
            "action": "query", "list": "prefixsearch", "pssearch": prefix, "pslimit": "6", "psnamespace": "0",
        ])
        guard let query = json["query"] as? [String: Any],
              let hits = query["prefixsearch"] as? [[String: Any]] else { return [] }
        return hits.compactMap { $0["title"] as? String }
    }

    static func randomTitle() async throws -> String {
        let json = try await get([
            "action": "query", "list": "random", "rnnamespace": "0", "rnlimit": "1",
        ])
        guard let query = json["query"] as? [String: Any],
              let random = query["random"] as? [[String: Any]],
              let title = random.first?["title"] as? String else { throw WikiError.badResponse }
        return title
    }

    // MARK: Loading

    private static func load(title: String) async throws -> Article {
        async let parsed = parse(title: title)
        async let meta = metadata(title: title)
        let (html, resolvedTitle) = try await parsed
        let info = try? await meta

        let root = HTMLParser.parse(html)
        let builder = ArticleBuilder()
        builder.build(root)

        let leadImage = info?.image ?? builder.infoboxImage
        let leadFile = info?.imageFile ?? builder.infoboxImage?.file
        let (blocks, sections, figureCaption) = builder.finish(leadImageFile: leadFile)
        // The header shows the lead image, so the infobox doesn't repeat it.
        var infobox = builder.infobox
        var leadCaption: AttributedString?
        if let leadFile {
            infobox = infobox.compactMap { row in
                guard case .image(let images, let caption) = row, images.contains(where: { $0.file == leadFile }) else { return row }
                let remaining = images.filter { $0.file != leadFile }
                if remaining.isEmpty {
                    if leadCaption == nil { leadCaption = caption }
                    return nil
                }
                return .image(remaining, caption: caption)
            }
        }
        leadCaption = leadCaption ?? figureCaption
        let summary = info?.summary
        let url = info?.url ?? URL(string: "https://en.wikipedia.org/wiki/" + (resolvedTitle.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))!
        return Article(
            title: resolvedTitle,
            summary: summary,
            url: url,
            leadImage: leadImage,
            leadCaption: leadCaption,
            infobox: infobox,
            blocks: blocks,
            sections: sections,
            plainText: ArticleBuilder.plainText(title: resolvedTitle, summary: summary, infobox: infobox, blocks: blocks)
        )
    }

    private static func parse(title: String) async throws -> (html: String, title: String) {
        let json = try await get([
            "action": "parse", "page": title, "prop": "text|displaytitle", "redirects": "1",
            "disableeditsection": "1", "disabletoc": "1", "disablelimitreport": "1",
        ])
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? String ?? ""
            if code == "missingtitle" || code == "invalidtitle" || code == "missingparam" { throw WikiError.notFound(title) }
            throw WikiError.badResponse
        }
        guard let parse = json["parse"] as? [String: Any],
              let html = parse["text"] as? String,
              let resolved = parse["title"] as? String else { throw WikiError.badResponse }
        return (html, resolved)
    }

    private struct Metadata {
        var summary: String?
        var image: WikiImage?
        var imageFile: String?
        var url: URL?
    }

    private static func metadata(title: String) async throws -> Metadata {
        let json = try await get([
            "action": "query", "titles": title, "redirects": "1", "prop": "pageimages|description|info",
            "piprop": "thumbnail|name", "pithumbsize": "1280", "inprop": "url",
        ])
        guard let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let page = pages.first, page["missing"] == nil else { return Metadata() }
        var result = Metadata()
        result.summary = (page["description"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let thumbnail = page["thumbnail"] as? [String: Any],
           let source = thumbnail["source"] as? String, let url = URL(string: source) {
            result.image = WikiImage(
                url: url,
                width: (thumbnail["width"] as? Double) ?? 0,
                height: (thumbnail["height"] as? Double) ?? 0,
                file: (page["pageimage"] as? String).map { "File:" + $0.replacingOccurrences(of: "_", with: " ") }
            )
            result.imageFile = result.image?.file
        }
        if let full = page["fullurl"] as? String { result.url = URL(string: full) }
        return result
    }

    private static func bestMatch(for query: String) async throws -> String? {
        var term = query
        for _ in 0..<2 {
            let json = try await get([
                "action": "query", "list": "search", "srsearch": term, "srlimit": "1", "srnamespace": "0",
                "srinfo": "suggestion", "srprop": "",
            ])
            guard let result = json["query"] as? [String: Any] else { return nil }
            if let hits = result["search"] as? [[String: Any]], let title = hits.first?["title"] as? String {
                return title
            }
            guard let info = result["searchinfo"] as? [String: Any],
                  let suggestion = info["suggestion"] as? String, suggestion != term else { return nil }
            term = suggestion
        }
        return nil
    }

    // MARK: HTTP

    private static func get(_ parameters: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        var items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "formatversion", value: "2")]
        components.queryItems = items.sorted { $0.name < $1.name }
        // PHP reads "+" as a space; keep titles like "C++" intact.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: components.url!)
        } catch let error as URLError where error.code != .cancelled {
            throw WikiError.offline
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WikiError.badResponse
        }
        return json
    }
}
