import SwiftUI
import PDFKit
import Combine
import AVKit

/// Active drawing tool on the slide.
enum Tool { case none, pen, laser }

/// The fixed pen palette, shared by the in-app colour swatches and the menu bar.
enum PenPalette {
    static let colors: [(name: String, color: Color)] =
        [("Red", PenInk.red), ("Yellow", PenInk.yellow),
         ("Green", PenInk.green), ("Blue", PenInk.blue)]
}

/// One freehand annotation, stored in *unit* coordinates (0...1 of the slide
/// rect) and a *relative* width so it scales identically on the small presenter
/// pane and the full audience screen.
struct Stroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
    var width: CGFloat   // fraction of slide width
}

/// Single source of truth shared by both windows. A keypress or click mutates
/// state here and the presenter + audience views update in lockstep.
final class PresentationState: ObservableObject {
    @Published private(set) var sourceURL: URL?          // the opened PDF on disk
    @Published private(set) var slideDoc: PDFDocument?   // left half (or full page)
    @Published private(set) var notesDoc: PDFDocument?   // right half, nil for plain PDFs
    @Published private(set) var textNotes: [Int: String] = [:]   // notes parsed from a sibling .tex
    @Published private(set) var movieMarks: [Int: MovieMark] = [:]   // \framemovie{} marks parsed from a sibling .tex
    @Published private(set) var pageCount: Int = 0
    @Published private(set) var isLoaded: Bool = false

    /// True when this deck has any notes at all — either a PDF notes column or
    /// `\note{}` text read from the `.tex` source.
    var hasNotes: Bool { notesDoc != nil || !textNotes.isEmpty }
    @Published private(set) var title: String = ""
    @Published private(set) var slideAspect: CGFloat = 16.0 / 9.0

    @Published var index: Int = 0
    @Published var blackout: Bool = false
    @Published var showOverview: Bool = false
    @Published var scratch: String = ""          // free-form notes, saved next to the PDF as .txt

    // Elapsed timer with start/stop/reset.
    @Published private(set) var timerRunning = true
    @Published private(set) var startDate = Date()   // start of the current running segment
    private var accumulated: TimeInterval = 0        // time banked from previous segments

    /// Total elapsed presentation time, accounting for pauses.
    var elapsedSeconds: TimeInterval {
        timerRunning ? accumulated + Date().timeIntervalSince(startDate) : accumulated
    }

    /// Optional lecture target in minutes (0 = off). A normal lecture slot is
    /// 45 min; a double slot is 90 min (2 × 45). Persisted across launches.
    @Published var lectureMinutes: Int = UserDefaults.standard.integer(forKey: "lectureMinutes") {
        didSet { UserDefaults.standard.set(lectureMinutes, forKey: "lectureMinutes") }
    }

    /// Seconds left until the lecture target (negative once over), or nil if off.
    var remainingSeconds: TimeInterval? {
        lectureMinutes > 0 ? TimeInterval(lectureMinutes * 60) - elapsedSeconds : nil
    }

    /// Whiteboard appearance on screen: a white board or the dark Night board.
    /// Persisted across launches. The PDF/board export always stays light.
    @Published var boardLight: Bool = UserDefaults.standard.bool(forKey: "boardLight") {
        didSet { UserDefaults.standard.set(boardLight, forKey: "boardLight") }
    }

    /// The style the on-screen board renders in (presenter + audience).
    var boardStyle: BoardStyle { boardLight ? .light : .dark }

    // Mentimeter: when active, the audience screen shows the live present view.
    @Published var mentiActive = false
    @Published var mentiPresentURL: URL?

    func startMenti(_ url: URL) { mentiPresentURL = url; mentiActive = true }
    func stopMenti() { mentiActive = false }

    // Annotation / laser
    @Published var tool: Tool = .none
    @Published var penColor: Color = .red
    @Published var strokes: [Int: [Stroke]] = [:] { didSet { hasUnsavedChanges = true } }
    @Published var currentStroke: [CGPoint] = []
    @Published var laserPoint: CGPoint?

    // Whiteboards (blank scratch slides). `activeBoardIndex == nil` means the
    // deck is showing; a non-nil index overlays that board on both screens.
    @Published var boards: [Whiteboard] = [] { didSet { hasUnsavedChanges = true } }
    @Published var activeBoardIndex: Int?
    @Published var selectedItemID: UUID?
    @Published var boardStroke: [CGPoint] = []   // in-progress ink on the board

    /// True once the deck has unexported ink or whiteboard edits. Set whenever the
    /// strokes/boards change, cleared on load, unload, and a successful export — so
    /// the app can offer to save before the deck is closed or discarded.
    @Published private(set) var hasUnsavedChanges = false

    /// Call after the deck has been exported to a PDF: the edits are now saved.
    func markSaved() { hasUnsavedChanges = false }

    private var thumbCache: [Int: NSImage] = [:]

    // One AVPlayer per page carrying a `\framemovie` mark, shared by every
    // `MovieOverlay` showing that page (presenter's current/next panes, the
    // audience window). They must be the literal same object, not separate
    // players pointed at the same file — AVPlayer's playback state (play/
    // pause/seek) isn't synced across instances, so a shared instance is what
    // makes the presenter's play button actually control what the audience
    // sees, instead of only the pane it was pressed in.
    private var moviePlayers: [Int: AVPlayer] = [:]

    /// Returns the shared player for this page, creating it on first use.
    func moviePlayer(forPage pageIndex: Int, url: URL) -> AVPlayer {
        if let existing = moviePlayers[pageIndex] { return existing }
        let player = AVPlayer(url: url)
        moviePlayers[pageIndex] = player
        return player
    }

    // MARK: - Loading

    @discardableResult
    func load(url: URL) -> Bool {
        guard let probe = PDFDocument(url: url), probe.pageCount > 0 else { return false }
        let split = PDFModel.isNotesLayout(probe)
        if isLoaded { recordCurrentSession(); saveScratch() }   // finish the previous deck first
        sourceURL = url

        slideDoc = PDFModel.croppedDocument(url: url, half: split ? .left : .full)
        notesDoc = split ? PDFModel.croppedDocument(url: url, half: .right) : nil
        guard let doc = slideDoc, let first = doc.page(at: 0) else { return false }

        let box = first.bounds(for: .cropBox)
        slideAspect = box.width / max(box.height, 1)
        pageCount = doc.pageCount
        // A split deck already carries its notes in the right half; for a plain
        // PDF, fall back to `\note{}` text from a sibling `.tex`, then to
        // PowerPoint speaker notes from a sibling `.pptx` (converted decks).
        if split {
            textNotes = [:]
        } else {
            let tex = TexNotes.load(forPDF: url, pageCount: doc.pageCount)
            textNotes = tex.isEmpty ? PptxNotes.load(forPDF: url, pageCount: doc.pageCount) : tex
        }
        // Independent of the notes layout -- a movie frame can appear in a
        // split (second-screen-notes) deck just as well as a plain one.
        movieMarks = MediaMarks.load(forPDF: url, pageCount: doc.pageCount)
        title = url.deletingPathExtension().lastPathComponent
        loadScratch()
        thumbCache.removeAll()
        moviePlayers.values.forEach { $0.pause() }
        moviePlayers.removeAll()
        strokes.removeAll()
        currentStroke = []
        laserPoint = nil
        tool = .none
        boards.removeAll()
        activeBoardIndex = nil
        selectedItemID = nil
        boardStroke = []
        index = 0
        // Start blacked out unless the user turned it off in Settings.
        blackout = UserDefaults.standard.object(forKey: "startBlackedOut") as? Bool ?? true
        showOverview = false
        accumulated = 0
        timerRunning = true
        startDate = Date()
        isLoaded = true
        hasUnsavedChanges = false   // a freshly loaded deck has nothing to save yet
        return true
    }

    func unload() {
        recordCurrentSession()
        saveScratch()
        scratch = ""
        sourceURL = nil
        slideDoc = nil
        notesDoc = nil
        textNotes = [:]
        movieMarks = [:]
        moviePlayers.values.forEach { $0.pause() }
        moviePlayers.removeAll()
        pageCount = 0
        title = ""
        thumbCache.removeAll()
        strokes.removeAll()
        currentStroke = []
        laserPoint = nil
        tool = .none
        boards.removeAll()
        activeBoardIndex = nil
        selectedItemID = nil
        boardStroke = []
        index = 0
        blackout = false
        showOverview = false
        isLoaded = false
        hasUnsavedChanges = false
        mentiActive = false
        mentiPresentURL = nil
    }

    // MARK: - Scratch notes & session stats

    /// Free-form scratch notes are stored as `<pdf-name>.notes.txt` next to the PDF.
    private var scratchURL: URL? {
        sourceURL?.deletingPathExtension().appendingPathExtension("notes").appendingPathExtension("txt")
    }

    private func loadScratch() {
        if let url = scratchURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            scratch = text
        } else {
            scratch = ""
        }
    }

    func saveScratch() {
        guard let url = scratchURL else { return }
        if scratch.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? scratch.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Records the elapsed time of the current deck into the usage stats.
    func recordCurrentSession() {
        guard isLoaded else { return }
        Stats.record(seconds: elapsedSeconds)
        accumulated = 0           // so a later call doesn't double-count
        startDate = Date()
    }

    // MARK: - Navigation

    func next()      { go(to: index + 1) }
    func previous()  { go(to: index - 1) }
    func goToFirst() { go(to: 0) }
    func goToLast()  { go(to: pageCount - 1) }

    func go(to i: Int) {
        guard pageCount > 0 else { return }
        if activeBoardIndex != nil { hideBoard() }   // navigating slides leaves the board
        let clamped = min(max(0, i), pageCount - 1)
        if clamped != index {
            currentStroke = []
            laserPoint = nil
        }
        index = clamped
    }

    func resetTimer() {
        accumulated = 0
        startDate = Date()
    }

    /// Pauses or resumes the elapsed timer.
    func toggleTimer() {
        if timerRunning {
            accumulated += Date().timeIntervalSince(startDate)
            timerRunning = false
        } else {
            startDate = Date()
            timerRunning = true
        }
    }

    // MARK: - Tools / annotations

    func toggleTool(_ t: Tool) {
        tool = (tool == t) ? .none : t
        if tool != .laser { laserPoint = nil }
        if tool != .pen { currentStroke = [] }
    }

    func beginStroke(at p: CGPoint) { currentStroke = [p] }
    func extendStroke(to p: CGPoint) { currentStroke.append(p) }

    func endStroke(width: CGFloat = 0.004) {
        defer { currentStroke = [] }
        guard currentStroke.count > 1 else { return }
        strokes[index, default: []].append(Stroke(points: currentStroke, color: penColor, width: width))
    }

    func setLaser(_ p: CGPoint?) { laserPoint = p }

    /// Undo / clear / "has ink" route to the active board when one is showing,
    /// so the control bar and keyboard shortcuts work in both contexts.
    func undoStroke() {
        if activeBoardIndex != nil { boardUndo(); return }
        guard var s = strokes[index], !s.isEmpty else { return }
        s.removeLast()
        strokes[index] = s.isEmpty ? nil : s
    }

    func clearStrokes() {
        if activeBoardIndex != nil { boardClearInk(); return }
        strokes[index] = nil
        currentStroke = []
    }

    var hasInkOnCurrentSlide: Bool {
        if let board = activeBoard { return !board.strokes.isEmpty }
        return !(strokes[index]?.isEmpty ?? true)
    }

    // MARK: - Whiteboards

    var activeBoard: Whiteboard? {
        guard let i = activeBoardIndex, boards.indices.contains(i) else { return nil }
        return boards[i]
    }

    var isBoardActive: Bool { activeBoardIndex != nil }

    /// True when there's nothing drawn or placed on the active board yet.
    var activeBoardIsEmpty: Bool {
        guard let board = activeBoard else { return true }
        return board.strokes.isEmpty && board.items.isEmpty
    }

    /// True when the deck has any ink or whiteboards worth exporting.
    var hasAnnotations: Bool {
        !boards.isEmpty || strokes.values.contains { !$0.isEmpty }
    }

    var selectedItem: BoardItem? {
        guard let id = selectedItemID else { return nil }
        return activeBoard?.items.first { $0.id == id }
    }

    func toggleBoard() { isBoardActive ? hideBoard() : showBoards() }

    /// Shows a board, creating the first one on demand.
    func showBoards() {
        if boards.isEmpty {
            addBoard()
        } else {
            activeBoardIndex = min(activeBoardIndex ?? boards.count - 1, boards.count - 1)
        }
    }

    func hideBoard() {
        activeBoardIndex = nil
        selectedItemID = nil
        boardStroke = []
    }

    func addBoard() {
        boards.append(Whiteboard(name: "Whiteboard \(boards.count + 1)", slideIndex: index))
        activeBoardIndex = boards.count - 1
        selectedItemID = nil
        boardStroke = []
    }

    func nextBoard() {
        guard let i = activeBoardIndex, i + 1 < boards.count else { return }
        activeBoardIndex = i + 1
        selectedItemID = nil
    }

    func previousBoard() {
        guard let i = activeBoardIndex, i > 0 else { return }
        activeBoardIndex = i - 1
        selectedItemID = nil
    }

    func deleteActiveBoard() {
        guard let i = activeBoardIndex else { return }
        boards.remove(at: i)
        activeBoardIndex = boards.isEmpty ? nil : min(i, boards.count - 1)
        selectedItemID = nil
        boardStroke = []
    }

    private func mutateActiveBoard(_ change: (inout Whiteboard) -> Void) {
        guard let i = activeBoardIndex, boards.indices.contains(i) else { return }
        change(&boards[i])
    }

    // Items
    func addItem(_ kind: BoardItem.Kind) {
        let item = BoardItem.makeDefault(kind)
        mutateActiveBoard { $0.items.append(item) }
        selectedItemID = item.id
    }

    /// Inserts a text item pre-filled with `text` (used by the quick commands).
    func addTextItem(_ text: String) {
        var item = BoardItem.makeDefault(.text)
        item.text = text
        mutateActiveBoard { $0.items.append(item) }
        selectedItemID = item.id
    }

    func deleteItem(_ id: UUID) {
        mutateActiveBoard { $0.items.removeAll { $0.id == id } }
        if selectedItemID == id { selectedItemID = nil }
    }

    /// Adds an empty table of the chosen size (rows × columns), like the grid
    /// picker in Apple Notes.
    func addTable(rows: Int, columns: Int) {
        let r = max(1, rows), c = max(1, columns)
        let line = Array(repeating: "", count: c).joined(separator: " | ")
        let text = Array(repeating: line, count: r).joined(separator: "\n")
        let width = min(0.9, max(0.3, CGFloat(c) * 0.14))
        let item = BoardItem(kind: .table, center: CGPoint(x: 0.5, y: 0.4), width: width, text: text)
        mutateActiveBoard { $0.items.append(item) }
        selectedItemID = item.id
    }

    func updateItemText(_ id: UUID, _ text: String) {
        mutateActiveBoard { board in
            if let k = board.items.firstIndex(where: { $0.id == id }) { board.items[k].text = text }
        }
    }

    func moveItem(_ id: UUID, to center: CGPoint) {
        mutateActiveBoard { board in
            if let k = board.items.firstIndex(where: { $0.id == id }) {
                board.items[k].center = CGPoint(x: clamp01(center.x), y: clamp01(center.y))
            }
        }
    }

    func scaleItem(_ id: UUID, by factor: CGFloat) {
        mutateActiveBoard { board in
            if let k = board.items.firstIndex(where: { $0.id == id }) {
                board.items[k].width = min(max(0.05, board.items[k].width * factor), 1)
                board.items[k].fontScale = min(max(0.02, board.items[k].fontScale * factor), 0.2)
            }
        }
    }

    /// Sets an item's width (e.g. from a drag handle), scaling its font to match.
    func setItemWidth(_ id: UUID, _ width: CGFloat) {
        mutateActiveBoard { board in
            guard let k = board.items.firstIndex(where: { $0.id == id }) else { return }
            let old = max(board.items[k].width, 0.0001)
            let w = min(max(width, 0.05), 1)
            board.items[k].width = w
            board.items[k].fontScale = min(max(board.items[k].fontScale * (w / old), 0.02), 0.2)
        }
    }

    func deleteSelectedItem() {
        guard let id = selectedItemID else { return }
        mutateActiveBoard { $0.items.removeAll { $0.id == id } }
        selectedItemID = nil
    }

    // Board ink
    func boardBeginStroke(at p: CGPoint) { boardStroke = [p] }
    func boardExtendStroke(to p: CGPoint) { boardStroke.append(p) }

    func boardEndStroke(width: CGFloat = 0.004) {
        defer { boardStroke = [] }
        guard boardStroke.count > 1 else { return }
        let stroke = Stroke(points: boardStroke, color: penColor, width: width)
        mutateActiveBoard { $0.strokes.append(stroke) }
    }

    func boardUndo() {
        mutateActiveBoard { if !$0.strokes.isEmpty { $0.strokes.removeLast() } }
    }

    func boardClearInk() {
        mutateActiveBoard { $0.strokes.removeAll() }
        boardStroke = []
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(max(0, v), 1) }

    // MARK: - Thumbnails

    /// Lazily renders and caches a thumbnail of the slide half for the strip and
    /// the overview grid.
    func thumbnail(at i: Int, height: CGFloat = 110) -> NSImage? {
        guard let doc = slideDoc, i >= 0, i < doc.pageCount, let page = doc.page(at: i) else { return nil }
        if let cached = thumbCache[i] { return cached }
        let box = page.bounds(for: .cropBox)
        let aspect = box.width / max(box.height, 1)
        let size = NSSize(width: height * aspect, height: height)
        let image = page.thumbnail(of: size, for: .cropBox)
        thumbCache[i] = image
        return image
    }
}
