import SwiftUI
import PDFKit
import SceneKit

/// Overlays real, rotatable SceneKit viewers where a frame's `\threedmark{}`
/// calls sit next to their part's poster image (see MediaMarks.swift for the
/// macro and why its visible `\href` deliberately still points to GitHub
/// rather than a local file). One `Object3DOverlay` handles a whole page: a
/// page can carry several 3D marks (e.g. the "Chronic implant" frame's
/// parts), each placed on the Link annotation whose target is the `\href`
/// that follows its mark in the source (`Object3DMark.matches`) -- so other
/// links on the page, before or after, don't matter.
struct Object3DOverlay: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let marks: [Object3DMark]
    let deckFolder: URL

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(placed.enumerated()), id: \.offset) { _, item in
                Object3DView(url: item.url)
                    .frame(width: geo.size.width * item.rect.width, height: geo.size.height * item.rect.height)
                    .position(x: geo.size.width * item.rect.midX, y: geo.size.height * item.rect.midY)
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
