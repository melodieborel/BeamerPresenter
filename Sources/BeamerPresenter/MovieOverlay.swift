import SwiftUI
import PDFKit
import AVKit

/// Overlays a real, playable `AVPlayer` where `\framemovie{...}{...}{...}`
/// placed a poster image in the PDF — real PDF-embedded video isn't viable
/// (see the macro's comment in main.tex: beamer's `\movie` and pdfcomment's
/// `\pdfmovie` don't compile under XeLaTeX, and the packages that do compile
/// only play back through Flash, which is dead everywhere).
///
/// Position/size come from the PDF itself, not from re-deriving the theme's
/// title-bar/margin layout in Swift: `\framemovie` wraps the poster in
/// `\href{run:...}{...}`, which compiles to a real PDF Link annotation whose
/// `bounds` are exactly the poster's rendered rect. Reading that off the page
/// keeps the overlay pixel-aligned with the poster regardless of theme
/// margins.
///
/// A slide page is never just that one link, though -- this theme's nav bar
/// (beamerouterthemeMB.sty) stamps ~20 more Link annotations on every page
/// for its section-jump buttons, confirmed on the actual compiled deck (21
/// links total on the movie frame, 20 of them ~9.5pt-tall nav buttons at the
/// bottom edge). So this doesn't take the first link, which only happened to
/// work by coincidence of annotation order -- it takes the *largest* one by
/// area, since the poster is always a real content-sized image and the nav
/// buttons are always sliver-thin. That would break if a `\framemovie` frame
/// ever also carried another large link; the robust fix then is matching the
/// annotation whose Launch target equals `mark.file`, which needs dropping to
/// the raw `/Annots` dictionaries via `page.pageRef` (PDFKit's `PDFAnnotation`
/// doesn't model Launch actions at the high level used here).
struct MovieOverlay: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let mark: MovieMark
    let deckFolder: URL

    var body: some View {
        GeometryReader { geo in
            if let url = mark.resolvedURL(inFolder: deckFolder), let rect = posterUnitRect {
                let player = state.moviePlayer(forPage: pageIndex, url: url)
                VideoPlayer(player: player)
                    .frame(width: geo.size.width * rect.width, height: geo.size.height * rect.height)
                    .position(x: geo.size.width * rect.midX, y: geo.size.height * rect.midY)
            }
        }
    }

    /// The poster's Link-annotation bounds, converted from PDF page space
    /// (origin bottom-left) to unit view space (origin top-left) so it can be
    /// scaled by whatever size `SlideView` is actually drawn at.
    private var posterUnitRect: CGRect? {
        guard let doc = state.slideDoc, let page = doc.page(at: pageIndex) else { return nil }
        // `PDFAnnotation.type` is the bare subtype name ("Link"), but
        // `PDFAnnotationSubtype.link.rawValue` is the raw PDF token including
        // its leading slash ("/Link") -- comparing them directly always
        // fails, which silently emptied `links` below and made this whole
        // overlay a no-op regardless of the PDF's actual content.
        let linkType = PDFAnnotationSubtype.link.rawValue.replacingOccurrences(of: "/", with: "")
        let links = page.annotations.filter { $0.type == linkType }
        guard let link = links.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return nil }
        let box = page.bounds(for: .cropBox)
        let r = link.bounds
        guard box.width > 0, box.height > 0 else { return nil }
        return CGRect(
            x: (r.minX - box.minX) / box.width,
            y: 1 - (r.maxY - box.minY) / box.height,
            width: r.width / box.width,
            height: r.height / box.height
        )
    }
}
