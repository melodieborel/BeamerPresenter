import Foundation

/// A movie placed on one frame via `\framemovie{file}{width}{height}` in the
/// `.tex` source (see collab-talk-alz-neuropixels/main.tex for the macro
/// definition and why real PDF-embedded video isn't viable). `file` is the
/// path passed to the macro (resolved the same way LaTeX's `\graphicspath`
/// would: next to the `.tex`, or under its `images/`/`../medias/`
/// subfolders). The macro's width/height args aren't captured here --
/// `MovieOverlay` positions/sizes the video by reading the poster's own Link
/// annotation off the compiled PDF instead, which lines up with the theme's
/// real layout (title bar, margins) without re-deriving it in Swift.
struct MovieMark {
    let file: String

    /// Resolves `file` against the deck's folder, trying the same relative
    /// locations `\graphicspath{{../medias/}{images/}}` in main.tex searches,
    /// plus the folder itself. Returns the first that actually exists.
    func resolvedURL(inFolder folder: URL) -> URL? {
        let candidates = [
            folder.appendingPathComponent(file),
            folder.appendingPathComponent("images").appendingPathComponent(file),
            folder.appendingPathComponent("../medias").appendingPathComponent(file),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Reads `\framemovie{...}{...}{...}` marks straight from the `.tex` source
/// next to a presentation, the same way `TexNotes` reads `\note{}` — same
/// frame-counting walk, same `.nav`-based page mapping, kept as its own
/// self-contained parser rather than sharing code with `TexNotes` (the two
/// have different per-frame payloads and there's no third user yet to justify
/// factoring out a shared walker).
enum MediaMarks {
    /// Returns a page-index → mark map for the PDF, using the same `.tex`
    /// candidate search as `TexNotes` (same base name first, then any other
    /// `.tex` in the folder). Returns an empty map when nothing usable is found.
    static func load(forPDF pdfURL: URL, pageCount: Int) -> [Int: MovieMark] {
        for texURL in candidateTexURLs(for: pdfURL) {
            let marks = marks(fromTex: texURL, pageCount: pageCount)
            if !marks.isEmpty { return marks }
        }
        return [:]
    }

    private static func candidateTexURLs(for pdfURL: URL) -> [URL] {
        let sameName = pdfURL.deletingPathExtension().appendingPathExtension("tex")
        let dir = pdfURL.deletingLastPathComponent()
        let others = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "tex" && $0 != sameName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return [sameName] + others
    }

    private static func marks(fromTex texURL: URL, pageCount: Int) -> [Int: MovieMark] {
        guard let source = readText(texURL) else { return [:] }

        let perFrame = framesWithMarks(in: source)
        guard !perFrame.isEmpty else { return [:] }

        let navURL = texURL.deletingPathExtension().appendingPathExtension("nav")
        let ranges = readText(navURL).map(framePages) ?? []

        var byPage: [Int: MovieMark] = [:]
        for (frame, mark) in perFrame {
            let pages: ClosedRange<Int>
            if frame < ranges.count {
                pages = ranges[frame]
            } else if ranges.isEmpty {
                pages = frame...frame
            } else {
                continue
            }
            for p in pages where p >= 0 && p < pageCount {
                byPage[p] = mark
            }
        }
        return byPage
    }

    // MARK: - File reading (identical to TexNotes)

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - .nav parsing (identical to TexNotes)

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

    /// Walks the (comment-stripped) source, counting frames exactly like
    /// `TexNotes` does, and collecting the `\framemovie{file}{w}{h}` call
    /// belonging to each one.
    private static func framesWithMarks(in rawSource: String) -> [Int: MovieMark] {
        let chars = Array(stripComments(rawSource))
        let n = chars.count
        var marks: [Int: MovieMark] = [:]
        var frame = -1
        var i = 0

        while i < n {
            guard chars[i] == "\\" else { i += 1; continue }

            var j = i + 1
            while j < n, chars[j].isLetter || chars[j] == "@" { j += 1 }
            if j == i + 1 { i += 2; continue }
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
            case "framemovie":
                // Three braced args (file, width, height) -- only `file` is
                // kept (see MovieMark), but all three must still be walked
                // past to leave `i` in the right place for the rest of the
                // source.
                var k = skipSpaces(chars, j)
                guard let (file, after1) = bracedGroup(chars, k) else { i = j; continue }
                k = skipSpaces(chars, after1)
                guard let (_, after2) = bracedGroup(chars, k) else { i = j; continue }
                k = skipSpaces(chars, after2)
                guard let (_, after3) = bracedGroup(chars, k) else { i = j; continue }
                if frame >= 0 {
                    marks[frame] = MovieMark(file: file)
                }
                i = after3
            default:
                i = j
            }
        }
        return marks
    }

    private static func skipSpaces(_ c: [Character], _ i: Int) -> Int {
        var i = i
        while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" { i += 1 }
        return i
    }

    private static func bracedGroup(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard i < c.count, c[i] == "{" else { return nil }
        var depth = 0
        var j = i
        let start = i + 1
        while j < c.count {
            let ch = c[j]
            if ch == "\\" { j += 2; continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return (String(c[start..<j]), j + 1) }
            }
            j += 1
        }
        return nil
    }

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
}
