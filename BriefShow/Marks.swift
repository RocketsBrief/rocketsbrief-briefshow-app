//
//  Marks.swift
//  BriefShow
//
//  Hand-drawn marks the app uses in place of SF Symbols, for the same reason
//  OpenFolderShape in ContentView.swift is hand-drawn: the glyph does not
//  exist. SF Symbols has no laboratory flask at all below macOS 14, and no
//  version of it has a flask with a sun cut in behind it.
//
//  Everything is drawn on a 100x100 grid and scaled to whatever frame it is
//  given, so one description serves the 15pt header button and any larger use
//  later without a second set of numbers.
//

import SwiftUI

// MARK: - LumenoLab

/// The Develop window's mark: a conical flask with bubbles, and a sun rising
/// behind it — the "Lumeno" and the "Lab" in one shape.
///
/// The sun is CUT by the flask rather than drawn behind it. Overlapping strokes
/// at 15pt turn into a grey smudge, and the cut is what keeps the two readable
/// as two things: it reads as depth even when the whole mark is fifteen points
/// across and one colour.
struct LumenoLabMark: View {
    /// Stroke weight on the 100-unit design grid. 7 lands at about 1pt when the
    /// mark is drawn at 15pt, which is the weight SF Symbols uses beside text
    /// this size — the point is to sit in the same row as `film` and
    /// `square.and.arrow.up` without looking lighter or heavier than they do.
    private let weight: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let box = CGRect(x: (proxy.size.width - side) / 2,
                             y: (proxy.size.height - side) / 2,
                             width: side, height: side)
            let line = weight / 100 * side

            ZStack {
                // The sun, with the flask punched out of it. Dilated by a
                // tenth before punching so a gap of clear space is left around
                // the flask instead of the two shapes touching, which at this
                // size would close up into a blot.
                SunMark()
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .mask(
                        FlaskCutout()
                            .fill(style: FillStyle(eoFill: true))
                    )

                FlaskMark()
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            }
            .frame(width: box.width, height: box.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Where the flask sits, in design-grid units, so the flask and the hole cut
/// for it in the sun cannot drift apart.
private enum FlaskGeometry {
    static let grid: CGFloat = 100

    /// The outline: neck, shoulders, rounded base. Open at the top, because a
    /// flask closed at the lip reads as a bottle.
    static func body(in rect: CGRect) -> Path {
        var path = Path()
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / grid * rect.width,
                    y: rect.minY + y / grid * rect.height)
        }

        path.move(to: at(41, 12))
        path.addLine(to: at(41, 36))
        path.addLine(to: at(20, 78))
        path.addQuadCurve(to: at(28, 89), control: at(20, 86))
        path.addLine(to: at(72, 89))
        path.addQuadCurve(to: at(80, 78), control: at(80, 86))
        path.addLine(to: at(59, 36))
        path.addLine(to: at(59, 12))
        return path
    }

    /// The lip, drawn across the open neck as its own stroke.
    static func lip(in rect: CGRect) -> Path {
        var path = Path()
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / grid * rect.width,
                    y: rect.minY + y / grid * rect.height)
        }
        path.move(to: at(35, 12))
        path.addLine(to: at(65, 12))
        return path
    }

    /// A filled silhouette of the whole flask, used both as the hole punched in
    /// the sun and as the test for which of the sun's rays are hidden behind
    /// it. `dilation` grows it about its own centre.
    ///
    /// The LIP is part of this, not just the body: without it the sun was drawn
    /// straight over the lip's own stroke with no gap between them, and two
    /// dark lines crossing at this size read as one thick smudge.
    static func silhouette(in rect: CGRect, dilation: CGFloat) -> Path {
        var solid = body(in: rect)
        solid.closeSubpath()
        // The lip is a bare line, so it is given width here by stroking it.
        solid.addPath(lip(in: rect).strokedPath(
            StrokeStyle(lineWidth: 9 / grid * min(rect.width, rect.height), lineCap: .round)))
        let bounds = solid.boundingRect
        return solid.applying(
            CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                .scaledBy(x: dilation, y: dilation)
                .translatedBy(x: -bounds.midX, y: -bounds.midY))
    }
}

private struct FlaskMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = FlaskGeometry.body(in: rect)
        path.addPath(FlaskGeometry.lip(in: rect))

        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / FlaskGeometry.grid * rect.width,
                    y: rect.minY + y / FlaskGeometry.grid * rect.height)
        }
        func bubble(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            let centre = at(x, y)
            let radius = r / FlaskGeometry.grid * min(rect.width, rect.height)
            path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2))
        }

        // Three, at three sizes, on no particular line. Evenly spaced bubbles
        // of one size read as a pattern rather than as something happening.
        //
        // All smaller than half the stroke width, so every one of them fills in
        // to a solid dot. A ring is the prettier bubble and it is the wrong
        // choice here: at 15pt its hole is well under a point and closes up on
        // some of them and not others, which looked like a drawing mistake
        // rather than like bubbles.
        bubble(36, 75, 3.2)
        bubble(52, 67, 2.2)
        bubble(60, 79, 2.7)
        return path
    }
}

private struct SunMark: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = FlaskGeometry.grid
        let unit = min(rect.width, rect.height) / grid
        let centre = CGPoint(x: rect.minX + 70 / grid * rect.width,
                             y: rect.minY + 21 / grid * rect.height)
        var path = Path()

        // The disc is left whole and let the mask bite into it: a curve cut
        // part-way through still reads as a circle continuing behind
        // something, which is the whole idea of the mark.
        let radius = 12.5 * unit
        path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                   width: radius * 2, height: radius * 2))

        // The rays are different: a straight stub with both ends cut off does
        // NOT read as a ray continuing behind the flask, it reads as a speck of
        // dirt — which is exactly how the first draft looked. So a ray is
        // either drawn whole or not at all, decided by whether its middle falls
        // inside the flask. Tested against the same silhouette the mask uses,
        // so the two can never disagree about where the flask is.
        let hidden = FlaskGeometry.silhouette(in: rect, dilation: 1.10)
        let inner = 17.5 * unit, outer = 25 * unit
        for step in 0..<8 {
            let angle = Double(step) * .pi / 4
            let start = CGPoint(x: centre.x + CGFloat(cos(angle)) * inner,
                                y: centre.y + CGFloat(sin(angle)) * inner)
            let end = CGPoint(x: centre.x + CGFloat(cos(angle)) * outer,
                              y: centre.y + CGFloat(sin(angle)) * outer)
            // Tested along its whole length, not just at the middle: a ray
            // whose middle is clear but whose END is not still comes back with
            // a bite out of it, which is the same speck-of-dirt that testing
            // the middle alone was meant to prevent.
            let samples = stride(from: 0.0, through: 1.0, by: 0.2).map { t in
                CGPoint(x: start.x + (end.x - start.x) * t,
                        y: start.y + (end.y - start.y) * t)
            }
            guard !samples.contains(where: { hidden.contains($0) }) else { continue }
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }
}

/// Everything EXCEPT the flask, as an even-odd fill: the outer rectangle is
/// deliberately far larger than the frame so the sun's rays are not clipped at
/// the edge of the box on their way out.
private struct FlaskCutout: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
        path.addPath(FlaskGeometry.silhouette(in: rect, dilation: 1.10))
        return path
    }
}

// MARK: - The BriefShow wordmark

/// "BriefShow" in the app's own two-tone wordmark, at whatever size is asked
/// for — the big one in ShowGrid's header and the small one inside the button
/// that opens the slideshow are the SAME mark, which is the point of it being
/// one view rather than two copies of the same two Text views.
struct BriefShowWordmark: View {
    var size: CGFloat = 20
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            Text("Brief")
                .foregroundColor(AppColors.wordmarkBright)
            Text("Show")
                .foregroundColor(AppColors.inkSecondary)
        }
        .font(.custom("Unbounded", size: size).weight(.black))
        // Tracking is negative and scales with the size: Unbounded Black is a
        // wide face, and at the header's 20pt it needs -1.7 to hold together.
        // Keeping the same ratio is what makes the button's smaller copy read
        // as the same wordmark rather than as a looser relative of it.
        .tracking(-1.7 / 20 * size)
    }
}
