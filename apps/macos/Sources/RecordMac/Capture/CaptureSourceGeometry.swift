import CoreGraphics
import Foundation

/// What a capture stream asks for to capture a source at its native size: the pixel size and,
/// for an area, the part of the display.
struct CaptureSourceGeometry: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    /// In the display's points, origin at its top left, as `SCStreamConfiguration.sourceRect`
    /// takes it; nil for the whole content.
    var sourceRect: CGRect?

    /// The whole content of a display or window filter: its size in points times its point to
    /// pixel scale.
    static func whole(pointSize: CGSize, scale: CGFloat) throws(CapturePrepareError) -> Self {
        let (width, height) = try pixels(pointSize, scale: scale, what: "the source")
        return Self(pixelWidth: width, pixelHeight: height, sourceRect: nil)
    }

    /// An area, given in global screen coordinates (points, origin at the bottom left of the main
    /// display), on a display whose frame is `displayFrame` in the same coordinates.
    static func area(_ area: CaptureArea, displayFrame: CGRect, scale: CGFloat) throws(CapturePrepareError) -> Self {
        let global = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
        guard area.width > 0, area.height > 0, displayFrame.contains(global) else {
            throw .settingsNotProducible(
                "the area \(area.width)x\(area.height) at (\(area.x), \(area.y)) does not lie within its display")
        }
        let local = CGRect(
            x: global.minX - displayFrame.minX, y: displayFrame.maxY - global.maxY,
            width: global.width, height: global.height)
        let (width, height) = try pixels(local.size, scale: scale, what: "the area")
        return Self(pixelWidth: width, pixelHeight: height, sourceRect: local)
    }

    /// Points to pixels, refused rather than rounded when the result is not whole pixels: a
    /// rounded size would capture a rescaled or cropped image.
    private static func pixels(_ size: CGSize, scale: CGFloat, what: String) throws(CapturePrepareError) -> (Int, Int) {
        let width = size.width * scale
        let height = size.height * scale
        guard scale > 0, width >= 1, height >= 1, width.isFinite, height.isFinite,
              width == width.rounded(), height == height.rounded()
        else {
            throw .settingsNotProducible(
                "\(what) is \(size.width)x\(size.height) points at scale \(scale), which is not a whole number of pixels")
        }
        return (Int(width), Int(height))
    }
}
