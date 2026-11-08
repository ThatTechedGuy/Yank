import AppKit
import ClipCore
import Testing

@testable import ClipSystem

// Proves the editor's image tools do what their buttons say: a rotation really turns the
// picture the way Preview's "Rotate Right" does (not the other way, which the same code with
// the wrong tag would do), and a cut-out really makes the background transparent while the
// subject keeps its colour. Real Core Image and Vision, since the framework calls are what
// could be wrong; the pictures are drawn in the test.
struct ImageEditorTests {
    /// A picture drawn with Core Graphics, as a PNG. The drawing block gets the context; its
    /// origin is the bottom-left corner, as in all of Core Graphics.
    func png(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        let image = try #require(context.makeImage())
        return try #require(Thumbnailer.pngData(image))
    }

    /// The red, green, blue and alpha of one pixel of a PNG, 0 to 255, counting x from the
    /// left and y from the top as in the editor.
    func pixel(_ png: Data, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(NSBitmapImageRep(data: png))
        let color = try #require(image.colorAt(x: x, y: y))
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { UInt8(($0 * 255).rounded()) }
    }

    let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    @Test func rotatingRightTurnsTheLeftEdgeIntoTheTop() throws {
        // Two pixels side by side: red on the left, blue on the right.
        let picture = try png(width: 2, height: 1) { context in
            context.setFillColor(red)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.setFillColor(blue)
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        }
        // A quarter turn clockwise stands them up with red on top; anticlockwise, blue on top.
        let right = try #require(ImageEditor.rotated(picture, clockwise: true))
        #expect(try #require(NSBitmapImageRep(data: right)).pixelsWide == 1)
        #expect(try #require(NSBitmapImageRep(data: right)).pixelsHigh == 2)
        #expect(try pixel(right, x: 0, y: 0)[0] == 255)
        #expect(try pixel(right, x: 0, y: 1)[2] == 255)
        let left = try #require(ImageEditor.rotated(picture, clockwise: false))
        #expect(try pixel(left, x: 0, y: 0)[2] == 255)
        #expect(try pixel(left, x: 0, y: 1)[0] == 255)
        #expect(ImageEditor.rotated(Data("not an image".utf8), clockwise: true) == nil)
    }

    @Test func removingTheBackgroundLeavesTheSubjectOnTransparency() async throws {
        // A red disc on white, the simplest "subject in front of a background".
        let picture = try png(width: 400, height: 400) { context in
            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            context.setFillColor(red)
            context.fillEllipse(in: CGRect(x: 100, y: 100, width: 200, height: 200))
        }
        let cutOut = try #require(try await ImageEditor.removingBackground(from: picture))
        // A corner (background) is fully transparent; the middle of the disc keeps its red
        // and stays opaque. The size is unchanged.
        #expect(try pixel(cutOut, x: 2, y: 2)[3] == 0)
        let centre = try pixel(cutOut, x: 200, y: 200)
        #expect(centre[3] == 255)
        #expect(centre[0] > 200 && centre[1] < 60 && centre[2] < 60)
        #expect(try #require(NSBitmapImageRep(data: cutOut)).pixelsWide == 400)
        #expect(try await ImageEditor.removingBackground(from: Data("not an image".utf8)) == nil)
    }
}
