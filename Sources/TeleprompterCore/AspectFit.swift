import Foundation

/// Normalized half-extents for an aspect-fit rectangle in Metal clip space.
public struct AspectFitScale: Equatable, Sendable {
    public let x: Float
    public let y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public enum AspectFit {
    /// Returns values in the range `0...1`. The larger axis is always `1`.
    public static func scale(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Double,
        targetHeight: Double,
        rotation: DisplayRotation = .degrees0
    ) -> AspectFitScale {
        let oriented = TransformGeometry.orientedSize(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            rotation: rotation
        )
        guard oriented.width > 0,
              oriented.height > 0,
              targetWidth > 0,
              targetHeight > 0 else {
            return AspectFitScale(x: 0, y: 0)
        }

        let sourceAspect = Double(oriented.width) / Double(oriented.height)
        let targetAspect = targetWidth / targetHeight

        if sourceAspect > targetAspect {
            return AspectFitScale(x: 1, y: Float(targetAspect / sourceAspect))
        }

        return AspectFitScale(x: Float(sourceAspect / targetAspect), y: 1)
    }
}
