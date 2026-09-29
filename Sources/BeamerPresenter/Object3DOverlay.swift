import SwiftUI
import PDFKit
import SceneKit

/// Overlays real, rotatable SceneKit viewers where a frame's `\threedmark{}`
/// calls sit next to their part's poster image (see MediaMarks.swift for the
/// macro and why its visible `\href` deliberately still points to GitHub
/// rather than a local file). One `Object3DOverlay` handles a whole page: a
/// page can carry several 3D marks (e.g. the "Chronic implant" frame's five
/// parts), each matched to its own Link annotation.
///
/// Matching is by **order**, not content: this page's Link annotations, in
/// document order, are zipped one-to-one with `marks` (also in source
/// order). Only the first `marks.count` links are used, so trailing links
/// unrelated to any `\threedmark` (this frame's internal Pinpoint-zoom
/// hyperlink, the Pinpoint URL, the eLife citation) are safely ignored *as
/// long as they come after all the part links in the PDF* -- true today
/// (verified against the compiled deck: the five GitHub STL links are first
/// in the page's annotation array), but would silently mis-pair everything
/// on this page if that ever changed. The robust fix, same as noted in
/// MovieOverlay, is matching each Link's actual Launch/URI target instead of
/// its position -- needs the raw `/Annots` dictionaries via `page.pageRef`.
struct Object3DOverlay: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let marks: [Object3DMark]
    let deckFolder: URL

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(pairedRects.enumerated()), id: \.offset) { _, pair in
                if let url = pair.mark.resolvedURL(inFolder: deckFolder) {
                    Object3DView(url: url)
                        .frame(width: geo.size.width * pair.rect.width, height: geo.size.height * pair.rect.height)
                        .position(x: geo.size.width * pair.rect.midX, y: geo.size.height * pair.rect.midY)
                }
            }
        }
    }

    private var pairedRects: [(mark: Object3DMark, rect: CGRect)] {
        guard let doc = state.slideDoc, let page = doc.page(at: pageIndex) else { return [] }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return [] }
        // `PDFAnnotation.type` is the bare subtype name ("Link"), but
        // `PDFAnnotationSubtype.link.rawValue` is the raw PDF token including
        // its leading slash ("/Link") -- comparing them directly always
        // fails (same bug fixed in MovieOverlay's posterUnitRect).
        let linkType = PDFAnnotationSubtype.link.rawValue.replacingOccurrences(of: "/", with: "")
        let links = page.annotations.filter { $0.type == linkType }
        return zip(marks, links).map { mark, link in
            let r = link.bounds
            let rect = CGRect(
                x: (r.minX - box.minX) / box.width,
                y: 1 - (r.maxY - box.minY) / box.height,
                width: r.width / box.width,
                height: r.height / box.height
            )
            return (mark, rect)
        }
    }
}

/// A single 3D object, rotated purely by dragging: `allowsCameraControl` is
/// SceneKit's own orbit-on-drag camera behavior, no custom gesture handling
/// needed. No camera/lights are added explicitly: `SceneView` auto-creates a
/// default camera framing the scene's content when the scene has none of its
/// own (true here -- the Blender conversion script that produced these
/// .usdz files doesn't add a camera), and `.autoenablesDefaultLighting`
/// covers lighting the same way.
private struct Object3DView: View {
    let url: URL

    // @State so the file loads once per view identity, not on every SwiftUI
    // re-render (a plain computed property would reload from disk -- and,
    // worse, hand SceneView a brand-new SCNScene instance each time, which
    // would reset any in-progress drag rotation).
    @State private var scene: SCNScene = SCNScene()

    var body: some View {
        SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            .onAppear {
                if let loaded = try? SCNScene(url: url, options: nil) {
                    scene = loaded
                }
            }
    }
}
