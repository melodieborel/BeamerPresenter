import SwiftUI

/// What the projector/external display shows: the slide full-bleed, the active
/// whiteboard, or — when blacked out (press `B`) — a black screen with an
/// optional centered message, falling back to the clock.
struct AudienceView: View {
    @EnvironmentObject var state: PresentationState
    @AppStorage("blackScreenMessage") private var blackMessage = ""

    var body: some View {
        ZStack {
            Color.black
            if state.mentiActive, let url = state.mentiPresentURL {
                MentiAudienceView(url: url)
            } else if let board = state.activeBoard {
                BoardCanvas(board: board, style: state.boardStyle)
                    .aspectRatio(state.slideAspect, contentMode: .fit)
                    .overlay {
                        if let laser = state.laserPoint {
                            BoardLaserDot(point: laser, color: state.penColor)
                        }
                    }
            } else {
                SlideView(pageIndex: state.index, interactive: false, liveWeb: true)
            }
            // Black-out is an overlay so `B` also covers a live Mentimeter poll
            // (without tearing down the web view / losing the session underneath).
            if state.blackout {
                BlackScreenView(message: blackMessage)
            }
        }
        .ignoresSafeArea()
    }
}

/// The blacked-out audience screen: an optional background image, an optional
/// centered message, and the clock (large on its own, or smaller beneath the
/// message). Sized relative to the screen so it reads from the back row.
private struct BlackScreenView: View {
    let message: String
    @AppStorage("blackScreenImage") private var imagePath = ""

    @State private var now = Date()
    @State private var dotOn = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasMessage: Bool { !trimmed.isEmpty }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Theme.blackout
                if let image = backgroundImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    Color.black.opacity(0.45)   // keep the text legible
                }

                VStack(spacing: s * 0.035) {
                    // Just the quiet pulsing dot — no label.
                    Circle().fill(Theme.statusOk)
                        .frame(width: max(7, s * 0.012), height: max(7, s * 0.012))
                        .shadow(color: Theme.statusOk.opacity(0.7), radius: 4)
                        .opacity(dotOn ? 1 : 0.2)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: dotOn)
                        .onAppear { dotOn.toggle() }
                    if hasMessage {
                        Text(trimmed)
                            .font(.display(s * 0.10))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                    }
                    Text(now, style: .time)
                        .font(.mono(s * (hasMessage ? 0.07 : 0.15), bold: true))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(s * 0.08)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(tick) { now = $0 }
    }

    private var backgroundImage: NSImage? {
        guard !imagePath.isEmpty else { return nil }
        return NSImage(contentsOfFile: imagePath)
    }
}
