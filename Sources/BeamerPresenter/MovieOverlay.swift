import SwiftUI
import PDFKit
import AVKit

/// Overlays a real, playable `AVPlayer` on each movie poster of a page —
/// real PDF-embedded video isn't viable (see the `\framemovie` macro's comment
/// in main.tex: beamer's `\movie` and pdfcomment's `\pdfmovie` don't compile
/// under XeLaTeX, and the packages that do compile only play back through
/// Flash, which is dead everywhere).
///
/// Position/size come from the PDF itself, not from re-deriving the theme's
/// title-bar/margin layout in Swift: the poster is wrapped in
/// `\href{run:<file>}{...}`, which compiles to a real PDF Link annotation whose
/// `bounds` are exactly the poster's rendered rect. Each movie takes the link
/// whose target is its own file (`MovieMark.matches`), so the theme's ~20
/// nav-bar links and any other links on the page (3D parts, a web view,
/// citations) can't be mistaken for it.
///
/// A movie without an audio track (an animation standing in for a GIF) plays
/// muted, loops, and starts as soon as its page is shown; one with sound waits
/// for the play button (see `PresentationState.moviePlayer`).
struct MovieOverlay: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let marks: [MovieMark]
    let deckFolder: URL

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(placed.enumerated()), id: \.offset) { _, item in
                let player = state.moviePlayer(forPage: pageIndex, url: item.url)
                VideoPlayer(player: player)
                    .frame(width: geo.size.width * item.rect.width, height: geo.size.height * item.rect.height)
                    .position(x: geo.size.width * item.rect.midX, y: geo.size.height * item.rect.midY)
                    .onAppear { if state.isLoopingMovie(player) { player.play() } }
            }
        }
    }

    private var placed: [(url: URL, rect: CGRect)] {
        guard let page = state.slideDoc?.page(at: pageIndex) else { return [] }
        let links = linkAnnotations(on: page)
        return marks.compactMap { mark in
            guard let url = mark.resolvedURL(inFolder: deckFolder),
                  let link = placeholderLink(in: links, mark.matches),
                  let rect = unitRect(of: link, on: page) else { return nil }
            return (url, rect)
        }
    }
}
