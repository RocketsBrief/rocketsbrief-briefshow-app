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

/// The photo editor's mark: a laboratory flask half full, with bubbles in the
/// liquid and a few rising through the neck.
///
/// Drawn to a reference the client supplied, in the app's own icon colour
/// rather than the reference's purple — every other glyph in that row is one
/// flat tone, and a coloured one would read as a badge rather than as a button.
///
/// The colour it IS given is whatever the button hands down, so it follows the
/// hover tint and all three themes without knowing about any of them. The
/// liquid and the bubbles are the same colour at lower opacity, which is what
/// keeps that true: a second hard-coded tone would have to be picked per theme
/// and would drift the moment one of them changed.
struct LumenoLabMark: View {
    /// Stroke weight on the 100-unit design grid. 8 lands at about 1.2pt when
    /// the mark is drawn at 15pt. Heavier than the 7 the first draft used,
    /// because the reference's outline is noticeably chunky and that weight is
    /// most of what makes it read as a flask rather than as a triangle.
    private let weight: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let line = weight / 100 * min(proxy.size.width, proxy.size.height)
            ZStack {
                // Liquid first, glass over the top — the order the two would
                // actually occlude in.
                //
                // No bubbles. They were drawn and taken back out on request,
                // and the mark is better for it: at 15pt four dots inside the
                // liquid turn into noise along the bottom edge, and what is
                // left — one shape, one flat tone inside it — is what reads.
                // 0.40, not the 0.32 this was drawn at: at 15pt a third of
                // the ink is nearly invisible against the button, and the
                // liquid is the whole difference between this and an empty
                // triangle. Checked at both sizes, not chosen from the big one.
                FlaskLiquid().fill().opacity(0.40)
                FlaskOutline()
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: The flask, on a 100x100 design grid

/// One description of the vessel, so the glass, the liquid inside it and the
/// bubbles cannot drift apart when any of the numbers change.
private enum Flask {
    static let neckLeft: CGFloat = 37, neckRight: CGFloat = 63
    static let neckTop: CGFloat = 14, shoulder: CGFloat = 44
    static let baseLeft: CGFloat = 9, baseRight: CGFloat = 91
    static let cornerTop: CGFloat = 78, bottom: CGFloat = 92
    static let lipLeft: CGFloat = 25, lipRight: CGFloat = 75
    /// Where the liquid sits. Just below the shoulder, as in the reference —
    /// a flask filled to the neck reads as full rather than as working.
    static let surface: CGFloat = 55

    static func point(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x / 100 * rect.width, y: rect.minY + y / 100 * rect.height)
    }

    static func unit(_ rect: CGRect) -> CGFloat { min(rect.width, rect.height) / 100 }

    /// How far out the sloping wall has reached at a given height. This is what
    /// lets the liquid's own top edge meet the glass exactly instead of being
    /// eyeballed to a second set of numbers.
    static func wallInset(atY y: CGFloat) -> CGFloat {
        let travel = (y - shoulder) / (cornerTop - shoulder)
        return (neckLeft - baseLeft) * min(max(travel, 0), 1)
    }

}

private struct FlaskOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { Flask.point(rect, x, y) }
        var path = Path()
        path.move(to: at(Flask.neckLeft, Flask.neckTop))
        path.addLine(to: at(Flask.neckLeft, Flask.shoulder))
        path.addLine(to: at(Flask.baseLeft, Flask.cornerTop))
        path.addQuadCurve(to: at(Flask.baseLeft + 13, Flask.bottom),
                          control: at(Flask.baseLeft, Flask.bottom))
        path.addLine(to: at(Flask.baseRight - 13, Flask.bottom))
        path.addQuadCurve(to: at(Flask.baseRight, Flask.cornerTop),
                          control: at(Flask.baseRight, Flask.bottom))
        path.addLine(to: at(Flask.neckRight, Flask.shoulder))
        path.addLine(to: at(Flask.neckRight, Flask.neckTop))

        // The lip, as its own stroke, so the neck stays open. A flask closed
        // across the top reads as a bottle.
        path.move(to: at(Flask.lipLeft, Flask.neckTop))
        path.addLine(to: at(Flask.lipRight, Flask.neckTop))
        return path
    }
}

/// What is in the flask: the lower part of the same vessel, cut flat at the
/// surface. Built from Flask.wallInset rather than from its own coordinates, so
/// the liquid's edges always land exactly on the glass.
private struct FlaskLiquid: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { Flask.point(rect, x, y) }
        let inset = Flask.wallInset(atY: Flask.surface)
        var path = Path()
        path.move(to: at(Flask.neckLeft - inset, Flask.surface))
        path.addLine(to: at(Flask.baseLeft, Flask.cornerTop))
        path.addQuadCurve(to: at(Flask.baseLeft + 13, Flask.bottom),
                          control: at(Flask.baseLeft, Flask.bottom))
        path.addLine(to: at(Flask.baseRight - 13, Flask.bottom))
        path.addQuadCurve(to: at(Flask.baseRight, Flask.cornerTop),
                          control: at(Flask.baseRight, Flask.bottom))
        path.addLine(to: at(Flask.neckRight + inset, Flask.surface))
        path.closeSubpath()
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
        // A wordmark that wraps is not a wordmark — squeezed, this broke as
        // "Brief Sho / w", with the W alone on a second line. Putting it on
        // its own row in the header was meant to prevent that, and it does
        // not: a row still hands out less width when the things beside it
        // want more. This says the mark simply does not compress.
        .lineLimit(1)
        .fixedSize()
    }
}
