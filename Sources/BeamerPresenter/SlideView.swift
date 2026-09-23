import SwiftUI

/// A slide rendered at its true aspect ratio with the annotation layer on top.
/// Because the PDF and the ink share one aspect-fit frame, unit-coordinate
/// strokes line up identically on the presenter pane and the full audience
/// screen.
struct SlideView: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let interactive: Bool

    var body: some View {
        ZStack {
            Color.black
            // PDFKit's own PDFView is fully interactive by default -- link
            // hover cursor, link clicks -- but nothing here has ever used
            // that (navigation is keyboard/UI-driven, ink has its own gesture
            // layer below). Left enabled, it silently wins the hover/click
            // for any Link annotation on the page, including the movie
            // poster's, ahead of MovieOverlay drawn on top of it: the cursor
            // shows PDFKit's pointing-hand hover style, and clicking invokes
            // nothing since PDFKit doesn't know how to run a /Launch action
            // -- which looked exactly like "no controls, can't click play."
            // Disabling hit-testing here removes PDFPageView as a competing
            // target so MovieOverlay is unambiguously what receives clicks.
            PDFPageView(document: state.slideDoc, pageIndex: pageIndex)
                .allowsHitTesting(false)
            AnnotationLayer(pageIndex: pageIndex, interactive: interactive)
            // Every SlideView showing this page (presenter panes, audience
            // window) gets the same MovieOverlay, which in turn fetches the
            // same shared AVPlayer from state -- so play/pause pressed on any
            // one of them plays everywhere, there's one audio pipeline either
            // way (one Mac, one output device).
            if let mark = state.movieMarks[pageIndex], let source = state.sourceURL {
                MovieOverlay(pageIndex: pageIndex, mark: mark, deckFolder: source.deletingLastPathComponent())
            }
        }
        .aspectRatio(state.slideAspect, contentMode: .fit)
    }
}

/// Draws committed strokes (and, on the current slide, the in-progress stroke +
/// laser dot). When `interactive`, a transparent layer captures pen/laser drags.
struct AnnotationLayer: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let interactive: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, sz in
                    for stroke in state.strokes[pageIndex] ?? [] {
                        ctx.stroke(path(stroke.points, in: sz),
                                   with: .color(stroke.color),
                                   style: lineStyle(stroke.width * sz.width))
                    }
                    if pageIndex == state.index {
                        if state.currentStroke.count > 1 {
                            ctx.stroke(path(state.currentStroke, in: sz),
                                       with: .color(state.penColor),
                                       style: lineStyle(0.004 * sz.width))
                        }
                        if let laser = state.laserPoint {
                            let r = 0.018 * sz.width
                            let c = CGPoint(x: laser.x * sz.width, y: laser.y * sz.height)
                            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                            ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.5, dy: r * 0.5)),
                                     with: .color(state.penColor))
                            ctx.fill(Path(ellipseIn: rect), with: .color(state.penColor.opacity(0.35)))
                        }
                    }
                }

                if interactive && state.tool != .none && pageIndex == state.index {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let p = CGPoint(x: clamp(value.location.x / size.width),
                                                    y: clamp(value.location.y / size.height))
                                    switch state.tool {
                                    case .pen:
                                        if state.currentStroke.isEmpty {
                                            state.beginStroke(at: p)
                                        } else {
                                            state.extendStroke(to: p)
                                        }
                                    case .laser:
                                        state.setLaser(p)
                                    case .none:
                                        break
                                    }
                                }
                                .onEnded { _ in
                                    switch state.tool {
                                    case .pen:   state.endStroke()
                                    case .laser: state.setLaser(nil)
                                    case .none:  break
                                    }
                                }
                        )
                }
            }
        }
    }
}

private func path(_ points: [CGPoint], in size: CGSize) -> Path {
    var p = Path()
    guard let first = points.first else { return p }
    p.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
    for pt in points.dropFirst() {
        p.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height))
    }
    return p
}

private func lineStyle(_ width: CGFloat) -> StrokeStyle {
    StrokeStyle(lineWidth: max(1, width), lineCap: .round, lineJoin: .round)
}

private func clamp(_ v: CGFloat) -> CGFloat { min(max(0, v), 1) }
