import AppKit
import ImageIO
import UniformTypeIdentifiers

// Vector-drawn brand mark. No raster dependency or external asset license.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.973, green: 0.965, blue: 0.947, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.translateBy(x: 512, y: 512)
context.scaleBy(x: 0.75, y: 0.75)
context.setFillColor(CGColor(red: 0.81, green: 0.29, blue: 0.19, alpha: 1))
for index in 0..<6 {
    context.saveGState()
    context.rotate(by: CGFloat(index) * .pi / 3)
    context.fillEllipse(in: CGRect(x: -112, y: -460, width: 224, height: 530))
    context.restoreGState()
}
context.setFillColor(CGColor(red: 0.973, green: 0.965, blue: 0.947, alpha: 1))
context.fillEllipse(in: CGRect(x: -65, y: -65, width: 130, height: 130))
let image = context.makeImage()!
let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, image, nil)
precondition(CGImageDestinationFinalize(output))
