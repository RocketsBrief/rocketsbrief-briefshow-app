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

// MARK: - Create

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
struct CreateMark: View {
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

// MARK: - The C4S wordmark

/// "C4S" set in the app's own wordmark face, with the 4 a shade off the two
/// letters around it.
///
/// ⚠️ This is the TEXT mark, and it is what the header wears. The drawn logo
/// (C4SMark, below) is the app icon and the Disclaimer's heading; on the
/// header it was tried and sent back — *„ovde neka piše slovima C4S, u slovima
/// koji je bio BriefShow"*. The name in the header is type, not a picture, the
/// way "BriefShow" was before it.
///
/// The two-tone treatment is the old wordmark's, kept deliberately: "Brief" was
/// bright and "Show" was muted, and here the C and the S are bright while the 4
/// takes the muted tone. That is the "shade different" the client asked for —
/// it is the same contrast the mark has always had, moved onto the one glyph
/// the logo also picks out in a different colour.
struct C4SWordmark: View {
    var size: CGFloat = 20
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            Text("C")
                .foregroundColor(AppColors.wordmarkBright)
            Text("4")
                .foregroundColor(AppColors.inkSecondary)
            Text("S")
                .foregroundColor(AppColors.wordmarkBright)
        }
        .font(.custom("Unbounded", size: size).weight(.black))
        // The same negative tracking ratio the BriefShow wordmark used —
        // Unbounded Black is a wide face and needs it to hold together. Three
        // glyphs need less than nine did, hence the gentler figure.
        .tracking(-1.0 / 20 * size)
        // A wordmark that wraps is not a wordmark.
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - The C4S logo

/// The drawn logo: the app icon, and the mark at the head of the Disclaimer.
///
/// Not used in the header — see C4SWordmark for why. The asset is the logo with
/// its white background cut away (flood-filled from the edges, so the light "4"
/// inside the dark body survives), which is what lets it sit on any of the
/// three themes without a card behind it.
struct C4SMark: View {
    var size: CGFloat = 20

    var body: some View {
        Image("C4SLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 1.55, height: size * 1.55)
            .accessibilityLabel("C4S Suite")
    }
}
