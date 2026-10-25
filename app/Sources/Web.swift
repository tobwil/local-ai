import Foundation
import PDFKit

/// Websuche ohne API-Schlüssel (DuckDuckGo), wahlweise über eine eigene SearXNG-Instanz oder die Brave-Search-API.
enum WebSearch {
    struct Result { let title: String; let url: String; let snippet: String }

    enum Provider: String, CaseIterable, Identifiable {
        case duckduckgo, searxng, brave
        var id: String { rawValue }
        var label: String {
            switch self {
            case .duckduckgo: return "DuckDuckGo (ohne Schlüssel)"
            case .searxng: return "SearXNG (eigene Instanz)"
            case .brave: return "Brave Search API"
            }
        }
    }

    static var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: "searchProvider") ?? "") ?? .duckduckgo
    }

    static func search(_ query: String, max: Int) async throws -> [Result] {
        let results: [Result]
        switch provider {
        case .duckduckgo: results = try await duckduckgo(query)
        case .searxng: results = try await searxng(query)
        case .brave: results = try await brave(query)
        }
        return Array(results.prefix(max))
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func duckduckgo(_ query: String) async throws -> [Result] {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)&kl=de-de".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        let links = matches(html, #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#)
        let snippets = matches(html, #"<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)</a>"#).map { $0[0] }
        return links.enumerated().compactMap { i, m in
            guard let url = decodeDDG(m[0]), !url.contains("duckduckgo.com/y.js") else { return nil }
            return Result(title: HTMLText.inline(m[1]), url: url, snippet: i < snippets.count ? HTMLText.inline(snippets[i]) : "")
        }
    }

    /// DuckDuckGo verpackt Ziele als //duckduckgo.com/l/?uddg=<ziel>.
    private static func decodeDDG(_ href: String) -> String? {
        let h = href.replacingOccurrences(of: "&amp;", with: "&")
        if let comps = URLComponents(string: h.hasPrefix("//") ? "https:" + h : h),
           let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value { return target }
        return h.hasPrefix("http") ? h : nil
    }

    private static func searxng(_ query: String) async throws -> [Result] {
        let base = UserDefaults.standard.string(forKey: "searxngURL") ?? ""
        guard var comps = URLComponents(string: base.trimmingCharacters(in: .whitespaces) + "/search") else {
            throw ToolError.invalid("SearXNG-Adresse fehlt (Einstellungen)")
        }
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["results"] as? [[String: Any]] ?? []).map {
            Result(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", snippet: $0["content"] as? String ?? "")
        }
    }

    private static func brave(_ query: String) async throws -> [Result] {
        guard let key = Keychain.get("braveKey"), !key.isEmpty else { throw ToolError.invalid("Brave-API-Schlüssel fehlt (Einstellungen)") }
        var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "10")]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (json?["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return results.map {
            Result(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "",
                   snippet: HTMLText.inline($0["description"] as? String ?? ""))
        }
    }

    static func matches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }
    }
}

/// Webseiten lesbar machen: Hauptinhalt finden, Navigation weglassen, als Markdown ausgeben.
enum WebFetch {
    static func fetch(_ address: String, maxChars: Int, links: Bool) async throws -> String {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") else {
            throw ToolError.invalid("Ungültige URL")
        }
        var req = URLRequest(url: url)
        req.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("de,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if let code = http?.statusCode, code >= 400 { throw ToolError.invalid("HTTP \(code)") }

        var text: String
        if type.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(data: data)?.string ?? "(PDF ohne Text)"
        } else if type.contains("html") || type.isEmpty {
            let html = String(decoding: data, as: UTF8.self)
            text = HTMLText.markdown(html, base: http?.url ?? url, includeLinks: links)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n\n… (gekürzt, \(text.count) Zeichen insgesamt)" }
        return "Quelle: \((http?.url ?? url).absoluteString)\n\n" + text
    }
}

enum HTMLText {
    /// Ganze Seite → Markdown aus dem Hauptinhalt.
    static func markdown(_ html: String, base: URL, includeLinks: Bool) -> String {
        let title = WebSearch.matches(html, #"<title[^>]*>([\s\S]*?)</title>"#).first.map { inline($0[0]) } ?? ""
        var body = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe"] {
            body = body.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Hauptinhalt bevorzugen, wenn vorhanden.
        for tag in ["article", "main"] {
            if let m = WebSearch.matches(body, "<\(tag)[^>]*>([\\s\\S]*)</\(tag)>").first, m[0].count > 500 { body = m[0]; break }
        }
        for tag in ["nav", "header", "footer", "aside", "form"] {
            body = body.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }

        var linkList: [String] = []
        if includeLinks {
            for m in WebSearch.matches(body, ##"<a[^>]*href="([^"#][^"]*)"[^>]*>([\s\S]*?)</a>"##).prefix(80) {
                let label = inline(m[1])
                if let u = URL(string: m[0].replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                   !label.isEmpty { linkList.append("- [\(label)](\(u.absoluteString))") }
            }
        }

        var s = body
        let rules: [(String, String)] = [
            ("<h1[^>]*>", "\n\n# "), ("<h2[^>]*>", "\n\n## "), ("<h3[^>]*>", "\n\n### "), ("<h[4-6][^>]*>", "\n\n#### "),
            ("</h[1-6]>", "\n\n"), ("<li[^>]*>", "\n- "), ("<br\\s*/?>", "\n"), ("</p>", "\n\n"), ("<p[^>]*>", "\n\n"),
            ("</(div|section|tr|table|ul|ol|blockquote)>", "\n"), ("<(td|th)[^>]*>", " | "),
            ("<pre[^>]*>", "\n```\n"), ("</pre>", "\n```\n"), ("<(strong|b)>", "**"), ("</(strong|b)>", "**"),
        ]
        for (pattern, rep) in rules { s = s.replacingOccurrences(of: pattern, with: rep, options: [.regularExpression, .caseInsensitive]) }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = entities(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00a0]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var out = title.isEmpty ? s : "# \(title)\n\n\(s)"
        if !linkList.isEmpty { out += "\n\n## Links\n" + linkList.joined(separator: "\n") }
        return out
    }

    /// Kurzer Inline-Text (Titel, Snippets).
    static func inline(_ html: String) -> String {
        entities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func entities(_ s: String) -> String {
        var s = s
        for (e, c) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'",
                       "&apos;": "'", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&auml;": "ä", "&ouml;": "ö",
                       "&uuml;": "ü", "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß", "&euro;": "€"] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        // Numerische Entities (&#228; / &#xE4;)
        for m in WebSearch.matches(s, "&#(x?)([0-9a-fA-F]+);") {
            let code = UInt32(m[1], radix: m[0].isEmpty ? 10 : 16)
            if let code, let scalar = Unicode.Scalar(code) {
                s = s.replacingOccurrences(of: "&#\(m[0])\(m[1]);", with: String(Character(scalar)))
            }
        }
        return s
    }
}

/// Minimaler Keychain-Zugriff für API-Schlüssel.
enum Keychain {
    private static let service = "de.kisruptiv.kilokal"

    static func set(_ key: String, _ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
