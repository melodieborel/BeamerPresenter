import Foundation
import PDFKit

/// Resolves a file named in the `.tex` source against the deck's folder,
/// trying the same relative locations `\graphicspath{{../medias/}{images/}}`
/// in main.tex searches, plus the folder itself. Returns the first that
/// actually exists.
func resolveDeckFile(_ file: String, inFolder folder: URL) -> URL? {
    let candidates = [
        folder.appendingPathComponent(file),
        folder.appendingPathComponent("images").appendingPathComponent(file),
        folder.appendingPathComponent("../medias").appendingPathComponent(file),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

/// A movie placed on one frame, either via `\framemovie{file}{width}{height}`
/// (see collab-talk-alz-neuropixels/main.tex for the macro definition and why
/// real PDF-embedded video isn't viable) or via a bare
/// `\href{run:file}{poster}` -- which is all `\framemovie` expands to, and
/// what a movie placed inside a tikz node uses directly. The overlay is
/// positioned on the PDF Link annotation whose target is this file (see
/// `MovieOverlay`), so several movies can share a page.
struct MovieMark {
    let file: String

    func resolvedURL(inFolder folder: URL) -> URL? { resolveDeckFile(file, inFolder: folder) }

    /// Whether `link` is this movie's poster: PDFKit reports a `run:` link as a
    /// file URL resolved next to the PDF, so compare file names.
    func matches(_ link: PDFAnnotation) -> Bool {
        link.url?.isFileURL == true && link.url?.lastPathComponent == (file as NSString).lastPathComponent
    }
}

/// A 3D object (.usdz) placed via `\threedmark{file}` right before one of a
/// frame's existing `\href{https://github.com/...}{...}` part links (see
/// collab-talk-alz-neuropixels/main.tex, "Chronic implant" frame). Unlike
/// `\framemovie`, the visible link is left pointing at GitHub on purpose --
/// this marker only tells BeamerPresenter which local file to overlay live;
/// a plain shared PDF still falls back to GitHub's own STL viewer. `link` is
/// the target of the first `\href` after the mark in the source, which is
/// how the overlay finds its own Link annotation on the page.
struct Object3DMark {
    let file: String
    var link: String?

    func resolvedURL(inFolder folder: URL) -> URL? { resolveDeckFile(file, inFolder: folder) }
    func matches(_ annotation: PDFAnnotation) -> Bool { linkMatches(link, annotation) }
}

/// A live web page placed via `\webmark{file}` right before an
/// `\href{https://...}{screenshot}`: BeamerPresenter overlays a real web view
/// loading that URL on the audience screen, while a plain shared PDF keeps the
/// screenshot linking to the same page. `file` (may be empty) is handed to the
/// page whenever it asks for a file -- e.g. Pinpoint's "import experiment".
struct WebMark {
    let file: String
    var link: String?

    func resolvedFileURL(inFolder folder: URL) -> URL? {
        file.isEmpty ? nil : resolveDeckFile(file, inFolder: folder)
    }
    func matches(_ annotation: PDFAnnotation) -> Bool { linkMatches(link, annotation) }
}

/// Compares a link target as written in the `.tex` source (LaTeX-escaped, e.g.
/// `r\%C3\%A9sine`) with a Link annotation's URL, both percent-decoded.
private func linkMatches(_ texLink: String?, _ annotation: PDFAnnotation) -> Bool {
    guard let texLink, let url = annotation.url?.absoluteString else { return false }
    let unescaped = texLink.replacingOccurrences(of: "\\%", with: "%")
        .replacingOccurrences(of: "\\#", with: "#")
    return (unescaped.removingPercentEncoding ?? unescaped) == (url.removingPercentEncoding ?? url)
}

/// Unit-space rect (origin top-left, 0...1 of the page) of a Link annotation,
/// ready to scale by whatever size `SlideView` is drawn at.
func unitRect(of link: PDFAnnotation, on page: PDFPage) -> CGRect? {
    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let r = link.bounds
    return CGRect(x: (r.minX - box.minX) / box.width,
                  y: 1 - (r.maxY - box.minY) / box.height,
                  width: r.width / box.width,
                  height: r.height / box.height)
}

/// A page's Link annotations. `PDFAnnotation.type` is the bare subtype name
/// ("Link"), but `PDFAnnotationSubtype.link.rawValue` is the raw PDF token
/// including its leading slash ("/Link") -- comparing them directly always
/// fails, which once silently emptied this list.
func linkAnnotations(on page: PDFPage) -> [PDFAnnotation] {
    let linkType = PDFAnnotationSubtype.link.rawValue.replacingOccurrences(of: "/", with: "")
    return page.annotations.filter { $0.type == linkType }
}

/// The largest of the links satisfying `matches` -- the placeholder itself,
/// when the same target is also linked from a small caption on the page.
func placeholderLink(in links: [PDFAnnotation], _ matches: (PDFAnnotation) -> Bool) -> PDFAnnotation? {
    links.filter(matches).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
}

/// Page-index → marks maps for one deck.
struct MediaMarkSet {
    var movies: [Int: [MovieMark]] = [:]
    var objects3D: [Int: [Object3DMark]] = [:]
    var webs: [Int: [WebMark]] = [:]

    var isEmpty: Bool { movies.isEmpty && objects3D.isEmpty && webs.isEmpty }
}

/// Reads movie (`\framemovie`, `\href{run:...}`), `\threedmark{...}` and
/// `\webmark{...}` marks straight from the `.tex` source next to a
/// presentation, the same way `TexNotes` reads `\note{}` — same
/// frame-counting walk, same `.nav`-based page mapping.
enum MediaMarks {
    /// Uses the same `.tex` candidate search as `TexNotes` (same base name
    /// first, then any other `.tex` in the folder).
    static func load(forPDF pdfURL: URL, pageCount: Int) -> MediaMarkSet {
        for texURL in candidateTexURLs(for: pdfURL) {
            let result = marks(fromTex: texURL, pageCount: pageCount)
            if !result.isEmpty { return result }
        }
        return MediaMarkSet()
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

    private static func marks(fromTex texURL: URL, pageCount: Int) -> MediaMarkSet {
        guard let source = readText(texURL) else { return MediaMarkSet() }

        let perFrame = framesWithMarks(in: source)
        guard !perFrame.isEmpty else { return MediaMarkSet() }

        let navURL = texURL.deletingPathExtension().appendingPathExtension("nav")
        let ranges = readText(navURL).map(framePages) ?? []

        func byPage<T>(_ frames: [Int: [T]]) -> [Int: [T]] {
            var out: [Int: [T]] = [:]
            for (frame, marks) in frames {
                let pages: ClosedRange<Int>
                if frame < ranges.count { pages = ranges[frame] }
                else if ranges.isEmpty { pages = frame...frame }
                else { continue }
                for p in pages where p >= 0 && p < pageCount { out[p] = marks }
            }
            return out
        }

        return MediaMarkSet(movies: byPage(perFrame.movies),
                            objects3D: byPage(perFrame.objects3D),
                            webs: byPage(perFrame.webs))
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

    private static let movieExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Walks the (comment-stripped) source, counting frames exactly like
    /// `TexNotes` does, and collecting each frame's movies (`\framemovie` calls
    /// and `\href{run:<movie>}` links), `\threedmark{file}` and
    /// `\webmark{file}` calls, in source order. A 3D/web mark takes the target
    /// of the next `\href` as its link.
    private static func framesWithMarks(in rawSource: String) -> MediaMarkSet {
        let chars = Array(stripComments(rawSource))
        let n = chars.count
        var set = MediaMarkSet()
        var frame = -1
        var i = 0
        enum Pending { case object3D, web }
        var pending: Pending?

        while i < n {
            guard chars[i] == "\\" else { i += 1; continue }

            var j = i + 1
            while j < n, chars[j].isLetter || chars[j] == "@" { j += 1 }
            if j == i + 1 { i += 2; continue }
            let name = String(chars[(i + 1)..<j])

            switch name {
            case "frame", "againframe":
                frame += 1
                pending = nil
                i = j
            case "begin":
                if let (env, after) = bracedGroup(chars, skipSpaces(chars, j)), env == "frame" {
                    frame += 1
                    pending = nil
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
                if frame >= 0 { set.movies[frame, default: []].append(MovieMark(file: file)) }
                i = after3
            case "threedmark", "webmark":
                let k = skipSpaces(chars, j)
                guard let (file, after) = bracedGroup(chars, k) else { i = j; continue }
                if frame >= 0 {
                    if name == "threedmark" {
                        set.objects3D[frame, default: []].append(Object3DMark(file: file))
                        pending = .object3D
                    } else {
                        set.webs[frame, default: []].append(WebMark(file: file))
                        pending = .web
                    }
                }
                i = after
            case "href":
                // Only the target is read; the link text is walked like any
                // other source, so marks nested inside it are still found.
                let k = skipSpaces(chars, j)
                guard let (target, after) = bracedGroup(chars, k) else { i = j; continue }
                if frame >= 0 {
                    if target.hasPrefix("run:"),
                       movieExtensions.contains((target as NSString).pathExtension.lowercased()) {
                        set.movies[frame, default: []].append(MovieMark(file: String(target.dropFirst(4))))
                    }
                    switch pending {
                    case .object3D: set.objects3D[frame]![set.objects3D[frame]!.count - 1].link = target
                    case .web:      set.webs[frame]![set.webs[frame]!.count - 1].link = target
                    case nil:       break
                    }
                }
                pending = nil
                i = after
            default:
                i = j
            }
        }
        return set
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
