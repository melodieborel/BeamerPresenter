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

/// A 3D object (.usdz) placed via `\threedmark{file}` right before one of a
/// frame's existing `\href{https://github.com/...}{...}` part links (see
/// collab-talk-alz-neuropixels/main.tex, "Chronic implant" frame). Unlike
/// `\framemovie`, the visible link is left pointing at GitHub on purpose --
/// this marker only tells BeamerPresenter which local file to overlay live;
/// a plain shared PDF still falls back to GitHub's own STL viewer. Several
/// of these can exist on one frame, matched to that page's Link annotations
/// **by order**, not by content -- see `Object3DOverlay` for the matching
/// and its caveats.
struct Object3DMark {
    let file: String

    func resolvedURL(inFolder folder: URL) -> URL? {
        let candidates = [
            folder.appendingPathComponent(file),
            folder.appendingPathComponent("images").appendingPathComponent(file),
            folder.appendingPathComponent("../medias").appendingPathComponent(file),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Reads `\framemovie{...}{...}{...}` and `\threedmark{...}` marks straight
/// from the `.tex` source next to a presentation, the same way `TexNotes`
/// reads `\note{}` — same frame-counting walk, same `.nav`-based page
/// mapping. Both mark kinds are collected in one pass over the source (kept
/// together, rather than in separate self-contained parsers, since they're
/// now two users of the exact same frame/page-mapping walk).
enum MediaMarks {
    /// Returns page-index → mark maps for the PDF (movies get at most one
    /// mark per page; 3D objects can have several, in source order), using
    /// the same `.tex` candidate search as `TexNotes` (same base name first,
    /// then any other `.tex` in the folder).
    static func load(forPDF pdfURL: URL, pageCount: Int) -> (movies: [Int: MovieMark], objects3D: [Int: [Object3DMark]]) {
        for texURL in candidateTexURLs(for: pdfURL) {
            let result = marks(fromTex: texURL, pageCount: pageCount)
            if !result.movies.isEmpty || !result.objects3D.isEmpty { return result }
        }
        return ([:], [:])
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

    private static func marks(fromTex texURL: URL, pageCount: Int) -> (movies: [Int: MovieMark], objects3D: [Int: [Object3DMark]]) {
        guard let source = readText(texURL) else { return ([:], [:]) }

        let perFrame = framesWithMarks(in: source)
        guard !perFrame.movies.isEmpty || !perFrame.objects3D.isEmpty else { return ([:], [:]) }

        let navURL = texURL.deletingPathExtension().appendingPathExtension("nav")
        let ranges = readText(navURL).map(framePages) ?? []

        func pages(forFrame frame: Int) -> ClosedRange<Int>? {
            if frame < ranges.count { return ranges[frame] }
            if ranges.isEmpty { return frame...frame }
            return nil
        }

        var movieByPage: [Int: MovieMark] = [:]
        for (frame, mark) in perFrame.movies {
            guard let pages = pages(forFrame: frame) else { continue }
            for p in pages where p >= 0 && p < pageCount { movieByPage[p] = mark }
        }

        var objectsByPage: [Int: [Object3DMark]] = [:]
        for (frame, marks) in perFrame.objects3D {
            guard let pages = pages(forFrame: frame) else { continue }
            for p in pages where p >= 0 && p < pageCount { objectsByPage[p] = marks }
        }

        return (movieByPage, objectsByPage)
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
    /// `TexNotes` does, and collecting each frame's `\framemovie{file}{w}{h}`
    /// call (at most one -- a later one on the same frame overwrites) and
    /// its `\threedmark{file}` calls (as many as appear, in source order).
    private static func framesWithMarks(in rawSource: String) -> (movies: [Int: MovieMark], objects3D: [Int: [Object3DMark]]) {
        let chars = Array(stripComments(rawSource))
        let n = chars.count
        var movies: [Int: MovieMark] = [:]
        var objects3D: [Int: [Object3DMark]] = [:]
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
                    movies[frame] = MovieMark(file: file)
                }
                i = after3
            case "threedmark":
                let k = skipSpaces(chars, j)
                guard let (file, after) = bracedGroup(chars, k) else { i = j; continue }
                if frame >= 0 {
                    objects3D[frame, default: []].append(Object3DMark(file: file))
                }
                i = after
            default:
                i = j
            }
        }
        return (movies, objects3D)
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
