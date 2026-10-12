import Foundation

/// Reads LaTeX Beamer `\note{...}` speaker notes straight from the `.tex` source
/// next to a presentation, so a *plain* single-screen PDF can still show notes in
/// the presenter view — no `show notes on second screen` recompile required.
///
/// Page ranges come from the Beamer `.nav` file when it sits beside the PDF
/// (exact and overlay-aware); otherwise each frame is assumed to be a single
/// page, in document order.
enum TexNotes {
    /// Returns a page-index → note map for the PDF. It prefers a `.tex` with the
    /// same base name next to the PDF; if that is missing or carries no notes, it
    /// falls back to any other `.tex` in the same folder, using the first that has
    /// `\note{}` content. Returns an empty map when nothing usable is found.
    static func load(forPDF pdfURL: URL, pageCount: Int) -> [Int: String] {
        for texURL in candidateTexURLs(for: pdfURL) {
            let notes = notes(fromTex: texURL, pageCount: pageCount)
            if !notes.isEmpty { return notes }
        }
        return [:]
    }

    /// `.tex` files worth trying, same-name first, then the rest of the folder
    /// in a stable alphabetical order.
    private static func candidateTexURLs(for pdfURL: URL) -> [URL] {
        let sameName = pdfURL.deletingPathExtension().appendingPathExtension("tex")
        let dir = pdfURL.deletingLastPathComponent()
        let others = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "tex" && $0 != sameName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return [sameName] + others
    }

    /// Parses one `.tex` file into a page-index → note map, using the sibling
    /// `.nav` (same base name) for exact page ranges when available.
    private static func notes(fromTex texURL: URL, pageCount: Int) -> [Int: String] {
        guard let source = expandedSource(of: texURL) else { return [:] }

        let notes = framesWithNotes(in: source)        // frameIndex → cleaned note
        guard !notes.isEmpty else { return [:] }

        let navURL = texURL.deletingPathExtension().appendingPathExtension("nav")
        let ranges = readText(navURL).map(framePages) ?? []

        var byPage: [Int: String] = [:]
        for (frame, note) in notes {
            let pages: ClosedRange<Int>
            if frame < ranges.count {
                pages = ranges[frame]
            } else if ranges.isEmpty {
                pages = frame...frame              // one page per frame (0-based)
            } else {
                continue                           // nav present but frame unknown
            }
            for p in pages where p >= 0 && p < pageCount {
                byPage[p] = byPage[p].map { $0 + "\n\n" + note } ?? note
            }
        }
        return byPage
    }

    // MARK: - File reading

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// The comment-stripped source of `texURL` with every `\input{file}` /
    /// `\include{file}` replaced by that file's own (stripped, expanded)
    /// source, so frames kept in shared files are seen in document order --
    /// by this reader and by `MediaMarks`. Paths resolve like LaTeX does:
    /// against the main `.tex`'s folder (not the including file's), `.tex`
    /// added when there's no extension. Files not found there (e.g. reached
    /// only through TEXINPUTS) are left as the plain `\input` call.
    static func expandedSource(of texURL: URL) -> String? {
        guard let source = readText(texURL) else { return nil }
        return expandInputs(stripComments(source), folder: texURL.deletingLastPathComponent(), depth: 0)
    }

    private static func expandInputs(_ source: String, folder: URL, depth: Int) -> String {
        guard depth < 10,                                  // guards \input cycles
              let re = try? NSRegularExpression(pattern: #"\\(?:input|include)\s*\{([^{}]+)\}"#)
        else { return source }
        let ns = source as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            var name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if (name as NSString).pathExtension.isEmpty { name += ".tex" }
            guard let included = readText(folder.appendingPathComponent(name)) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += expandInputs(stripComments(included), folder: folder, depth: depth + 1)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: - .nav parsing

    /// Each `\beamer@framepages {start}{end}` in the `.nav` file gives the 1-based
    /// page range of a frame, emitted once per frame in document order. Converted
    /// here to 0-based closed ranges.
    private static func framePages(_ nav: String) -> [ClosedRange<Int>] {
        let pattern = #"\\beamer@framepages\s*\{(\d+)\}\{(\d+)\}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = nav as NSString
        var ranges: [ClosedRange<Int>] = []
        for m in re.matches(in: nav, range: NSRange(location: 0, length: ns.length)) {
            let a = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let b = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let lo = max(0, a - 1)
            let hi = max(lo, b - 1)
            ranges.append(lo...hi)
        }
        return ranges
    }

    // MARK: - .tex parsing

    /// Walks the (comment-stripped) source, counting frames and collecting the
    /// `\note{...}` bodies that belong to each one.
    private static func framesWithNotes(in rawSource: String) -> [Int: String] {
        let chars = Array(stripComments(rawSource))
        let n = chars.count
        var notes: [Int: String] = [:]
        var frame = -1            // index of the most recently opened frame
        var i = 0

        while i < n {
            guard chars[i] == "\\" else { i += 1; continue }

            // Read the control-word name (letters/`@`) following the backslash.
            var j = i + 1
            while j < n, chars[j].isLetter || chars[j] == "@" { j += 1 }
            if j == i + 1 { i += 2; continue }            // control symbol (\%, \{, …)
            let name = String(chars[(i + 1)..<j])

            switch name {
            case "frame", "againframe":
                frame += 1
                i = j
            case "begin":
                if let (env, after) = bracedGroup(chars, skipSpaces(chars, j)), env == "frame" {
                    frame += 1
                    i = after
                } else {
                    i = j
                }
            case "note":
                var k = skipSpaces(chars, j)
                k = skipOptional(chars, k, open: "<", close: ">")   // \note<2>{…}
                k = skipSpaces(chars, k)
                k = skipOptional(chars, k, open: "[", close: "]")   // \note[item]{…}
                k = skipSpaces(chars, k)
                if let (body, after) = bracedGroup(chars, k) {
                    let text = cleanup(body)
                    if frame >= 0, !text.isEmpty {
                        notes[frame] = notes[frame].map { $0 + "\n\n" + text } ?? text
                    }
                    i = after
                } else {
                    i = j
                }
            default:
                i = j
            }
        }
        return notes
    }

    private static func skipSpaces(_ c: [Character], _ i: Int) -> Int {
        var i = i
        while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" { i += 1 }
        return i
    }

    /// If `c[i]` opens an optional group, returns the index just past its close;
    /// otherwise returns `i` unchanged.
    private static func skipOptional(_ c: [Character], _ i: Int, open: Character, close: Character) -> Int {
        guard i < c.count, c[i] == open else { return i }
        var j = i + 1
        while j < c.count, c[j] != close { j += 1 }
        return j < c.count ? j + 1 : i
    }

    /// Reads a balanced `{ … }` group starting at `c[i] == "{"`, honouring nested
    /// braces and `\{` / `\}` escapes. Returns the inner text and the index past
    /// the closing brace.
    private static func bracedGroup(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard i < c.count, c[i] == "{" else { return nil }
        var depth = 0
        var j = i
        let start = i + 1
        while j < c.count {
            let ch = c[j]
            if ch == "\\" { j += 2; continue }            // skip escaped char
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return (String(c[start..<j]), j + 1) }
            }
            j += 1
        }
        return nil
    }

    // MARK: - Comment & markup cleanup

    /// Drops everything after an unescaped `%` on each line.
    private static func stripComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var escaped = false
            for ch in line {
                if escaped { out.append(ch); escaped = false; continue }
                if ch == "\\" { out.append(ch); escaped = true; continue }
                if ch == "%" { break }
                out.append(ch)
            }
            out.append("\n")
        }
        return out
    }

    /// Best-effort conversion of a LaTeX note body to readable plain text.
    private static func cleanup(_ tex: String) -> String {
        var s = tex

        // List markup → bullets / blank lines.
        s = regexReplace(s, #"\\(begin|end)\s*\{(itemize|enumerate|description)\}"#, "\n")
        s = s.replacingOccurrences(of: "\\item", with: "\n• ")
        s = s.replacingOccurrences(of: "\\par", with: "\n\n")
        s = s.replacingOccurrences(of: "\\\\", with: "\n")          // explicit line break

        // Common escaped specials.
        for (esc, plain) in [("\\&", "&"), ("\\%", "%"), ("\\_", "_"),
                             ("\\#", "#"), ("\\$", "$"), ("~", " ")] {
            s = s.replacingOccurrences(of: esc, with: plain)
        }

        // Unwrap simple `\cmd[..]{text}` to its argument (a few passes for nesting),
        // then drop any remaining bare commands and stray braces.
        for _ in 0..<3 {
            s = regexReplace(s, #"\\[a-zA-Z@]+\*?\s*(\[[^\]]*\])?\s*\{([^{}]*)\}"#, "$2")
        }
        s = regexReplace(s, #"\\[a-zA-Z@]+\*?"#, "")
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")

        // Tidy whitespace.
        s = regexReplace(s, #"[ \t]+"#, " ")
        s = regexReplace(s, #"\n{3,}"#, "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
