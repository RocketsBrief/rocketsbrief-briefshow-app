import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makePNG(_ w: Int, _ h: Int) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData(); let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d); return out as Data
}
func alphaAt(_ data: Data, _ x: Int, _ y: Int) -> Int {
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return Int(p[(y*w + x)*4 + 3])   // top row first
}
var fails = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok  " : "FAIL", name); if !ok { fails += 1 } }

// Photo 1000x500. Layer covers left half top-left quarter: x0 y0 w0.5 h0.5 -> 500x250 photo px, image 500x250.
let png = makePNG(500, 250)
let rect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
// Horizontal stroke through the layer's middle row (photo y = 0.25*... layer centre y = 125px = unit 0.25)
let stroke = [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.4, y: 0.25)]
// size 0.04 of long edge 1000 -> diameter 40, radius 20
let hard = LayerEraser.erasePixels(imageData: png, layerRect: rect, rotationDegrees: 0, stroke: stroke, brush: .init(size: 0.04, opacity: 1, feather: 0), photoPixelSize: CGSize(width: 1000, height: 500))!
check("hard: centre of stroke erased", alphaAt(hard, 250, 125) == 0)
check("hard: 18px off still erased", alphaAt(hard, 250, 143) == 0)
check("hard: 25px off untouched", alphaAt(hard, 250, 150) == 255)
check("hard: outside stroke length untouched", alphaAt(hard, 450, 125) == 255)

let soft = LayerEraser.erasePixels(imageData: png, layerRect: rect, rotationDegrees: 0, stroke: stroke, brush: .init(size: 0.04, opacity: 1, feather: 1), photoPixelSize: CGSize(width: 1000, height: 500))!
let mid = alphaAt(soft, 250, 135)
check("soft: centre erased", alphaAt(soft, 250, 125) <= 1)
check("soft: half radius partly kept (\(mid))", mid > 40 && mid < 230)

let half = LayerEraser.erasePixels(imageData: png, layerRect: rect, rotationDegrees: 0, stroke: stroke, brush: .init(size: 0.04, opacity: 0.5, feather: 0), photoPixelSize: CGSize(width: 1000, height: 500))!
let a = alphaAt(half, 250, 125)
check("opacity 50: centre half alpha (\(a))", abs(a - 128) <= 2)

// Rotated 90° layer centred: stroke horizontal in photo = vertical in layer image.
let square = makePNG(200, 200)
let rrect = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4) // 200x200 photo px on 1000x500
let rs = LayerEraser.erasePixels(imageData: square, layerRect: rrect, rotationDegrees: 90, stroke: [CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5)], brush: .init(size: 0.01, opacity: 1, feather: 0), photoPixelSize: CGSize(width: 1000, height: 500))!
check("rotated: photo-horizontal stroke is layer-vertical", alphaAt(rs, 100, 60) == 0 && alphaAt(rs, 60, 100) == 255)
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
