//
//  LayerEraser.swift
//  BriefShow
//
//  The Eraser on a selected layer. Asked for 17.09: *„Nemam ereaser tool
//  uopste da izaberem, kada dodajes to dodaj jacinu, opacity dok cisti i
//  fheater ili strong edges of the circle brush eraser tool!"*
//
//  A stroke is BAKED into the layer when the mouse comes up — the pixels of a
//  pasted piece lose alpha, the matte of a derived layer (Select People /
//  Background) loses coverage. Baked rather than stored as strokes because a
//  layer is already pixels, and because undo already snapshots the whole
//  settings record: Cmd+Z takes a stroke back like any other change.
//
//  Pure and static, so it runs off the main thread and can be driven from a
//  test without the app.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct LayerEraseBrush: Equatable {
    /// Diameter as a fraction of the PHOTO's long edge — the same unit the
    /// mask Brush uses, so one number means the same circle in both tools.
    var size: Double
    /// How much of what is under the brush is taken away, 0...1. 1 erases to
    /// nothing; 0.3 leaves 70 % of the piece behind.
    var opacity: Double
    /// 0 is a hard-edged circle, 1 fades from the centre all the way out.
    var feather: Double
}

enum LayerEraser {

    /// Erases `stroke` (points in photo unit space, top-down) out of a pixel
    /// layer's image. `photoPixelSize` is the photograph the layer sits on.
    /// Returns PNG data, or nil if nothing could be decoded.
    static func erasePixels(imageData: Data,
                            layerRect: CGRect,          // unit space of the photo
                            rotationDegrees: Double,
                            stroke: [CGPoint],
                            brush: LayerEraseBrush,
                            photoPixelSize: CGSize) -> Data? {
        guard let image = decode(imageData), photoPixelSize.width > 0, photoPixelSize.height > 0,
              layerRect.width > 0, layerRect.height > 0 else { return nil }
        let width = image.width, height = image.height

        // Photo pixels → the layer image's own pixels: undo the placement,
        // then the rotation about the layer's centre, then the scale.
        let pw = Double(photoPixelSize.width), ph = Double(photoPixelSize.height)
        let lw = layerRect.width * pw, lh = layerRect.height * ph
        let cx = layerRect.midX * pw, cy = layerRect.midY * ph
        let theta = rotationDegrees * .pi / 180
        let cosT = cos(theta), sinT = sin(theta)
        let sx = Double(width) / lw, sy = Double(height) / lh

        let local = stroke.map { point -> CGPoint in
            let dx = point.x * pw - cx, dy = point.y * ph - cy
            // The layer turns clockwise on screen (y down); undo that.
            let ux = dx * cosT + dy * sinT
            let uy = -dx * sinT + dy * cosT
            return CGPoint(x: (ux + lw / 2) * sx, y: (uy + lh / 2) * sy)
        }
        let radiusPhoto = max(brush.size * max(pw, ph) / 2, 0.5)
        let radii = CGSize(width: radiusPhoto * sx, height: radiusPhoto * sy)

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let coverage = self.coverage(width: width, height: height, points: local, radii: radii,
                                     feather: brush.feather)
        let strength = min(max(brush.opacity, 0), 1)
        // CGContext memory is top row first, and so is `coverage`.
        for (index, amount) in coverage.values {
            let keep = 1 - strength * Double(amount)
            let base = index * 4
            for channel in 0..<4 {
                pixels[base + channel] = UInt8((Double(pixels[base + channel]) * keep).rounded())
            }
        }
        guard let output = context.makeImage() else { return nil }
        return png(output)
    }

    /// Erases `stroke` out of a derived layer's matte. The matte covers the
    /// whole photograph, so unit space maps straight onto it.
    static func eraseMatte(maskData: Data,
                           stroke: [CGPoint],
                           brush: LayerEraseBrush,
                           photoPixelSize: CGSize) -> Data? {
        guard let image = decode(maskData), photoPixelSize.width > 0, photoPixelSize.height > 0 else {
            return nil
        }
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let local = stroke.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
        // Radius from the PHOTO's long edge, rescaled to the matte, which is
        // stored smaller than the photograph.
        let longPhoto = Double(max(photoPixelSize.width, photoPixelSize.height))
        let radiusPhoto = max(brush.size * longPhoto / 2, 0.5)
        let radii = CGSize(width: radiusPhoto * Double(width) / Double(photoPixelSize.width),
                           height: radiusPhoto * Double(height) / Double(photoPixelSize.height))

        let coverage = self.coverage(width: width, height: height, points: local, radii: radii,
                                     feather: brush.feather)
        let strength = min(max(brush.opacity, 0), 1)
        for (index, amount) in coverage.values {
            let keep = 1 - strength * Double(amount)
            pixels[index] = UInt8((Double(pixels[index]) * keep).rounded())
        }
        guard let output = context.makeImage() else { return nil }
        return png(output)
    }

    // MARK: - Coverage

    /// How much of each pixel the stroke covers, 0...1, as the MAXIMUM over
    /// its dabs — so going over the same spot twice in one stroke does not
    /// erase it harder, which is what Opacity promises. A second stroke does
    /// compound, the way it does in Photoshop.
    struct Coverage {
        var values: [(Int, Float)]
    }

    static func coverage(width: Int, height: Int, points: [CGPoint], radii: CGSize,
                         feather: Double) -> Coverage {
        guard !points.isEmpty, radii.width > 0, radii.height > 0 else { return Coverage(values: []) }

        // Dabs every quarter radius along the path, so a fast stroke is still
        // a continuous line and not a row of beads.
        let step = max(min(radii.width, radii.height) * 0.25, 0.5)
        var dabs: [CGPoint] = [points[0]]
        for pair in zip(points, points.dropFirst()) {
            let dx = pair.1.x - pair.0.x, dy = pair.1.y - pair.0.y
            let distance = (dx * dx + dy * dy).squareRoot()
            let count = max(Int(distance / step), 1)
            for i in 1...count {
                let t = Double(i) / Double(count)
                dabs.append(CGPoint(x: pair.0.x + dx * t, y: pair.0.y + dy * t))
            }
        }

        let minX = max(Int((dabs.map(\.x).min()! - radii.width).rounded(.down)), 0)
        let maxX = min(Int((dabs.map(\.x).max()! + radii.width).rounded(.up)), width - 1)
        let minY = max(Int((dabs.map(\.y).min()! - radii.height).rounded(.down)), 0)
        let maxY = min(Int((dabs.map(\.y).max()! + radii.height).rounded(.up)), height - 1)
        guard minX <= maxX, minY <= maxY else { return Coverage(values: []) }

        let boxWidth = maxX - minX + 1
        var grid = [Float](repeating: 0, count: boxWidth * (maxY - minY + 1))
        // Inside `hard` of the radius the brush is solid; from there to the
        // edge it falls off smoothly. Feather 0 still keeps one pixel of
        // falloff, so a hard eraser has a clean edge rather than a jagged one.
        let hard = 1 - min(max(feather, 0), 1)
        let edgePixels = 1 / max(min(radii.width, radii.height), 1)

        for dab in dabs {
            let x0 = max(Int(dab.x - radii.width), minX), x1 = min(Int(dab.x + radii.width) + 1, maxX)
            let y0 = max(Int(dab.y - radii.height), minY), y1 = min(Int(dab.y + radii.height) + 1, maxY)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                let ny = (Double(y) + 0.5 - dab.y) / radii.height
                for x in x0...x1 {
                    let nx = (Double(x) + 0.5 - dab.x) / radii.width
                    let r = (nx * nx + ny * ny).squareRoot()
                    guard r < 1 else { continue }
                    let value: Double
                    let inner = min(hard, 1 - edgePixels)
                    if r <= inner {
                        value = 1
                    } else {
                        let t = (r - inner) / max(1 - inner, 1e-6)
                        value = 1 - t * t * (3 - 2 * t)
                    }
                    let cell = (y - minY) * boxWidth + (x - minX)
                    if Float(value) > grid[cell] { grid[cell] = Float(value) }
                }
            }
        }

        var values: [(Int, Float)] = []
        values.reserveCapacity(grid.count / 2)
        for (cell, amount) in grid.enumerated() where amount > 0 {
            let y = cell / boxWidth + minY, x = cell % boxWidth + minX
            values.append((y * width + x, amount))
        }
        return Coverage(values: values)
    }

    // MARK: - IO

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
