public struct PixelDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum CaptureSizing {
    public static func fitted(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumDimension: Int
    ) -> PixelDimensions {
        guard sourceWidth > 0,
              sourceHeight > 0,
              maximumDimension > 0 else {
            return PixelDimensions(width: 0, height: 0)
        }

        let sourceMaximum = max(sourceWidth, sourceHeight)
        guard sourceMaximum > maximumDimension else {
            return PixelDimensions(
                width: sourceWidth,
                height: sourceHeight
            )
        }

        let scale = Double(maximumDimension) / Double(sourceMaximum)
        return PixelDimensions(
            width: evenDimension(Double(sourceWidth) * scale),
            height: evenDimension(Double(sourceHeight) * scale)
        )
    }

    private static func evenDimension(_ value: Double) -> Int {
        let roundedDown = max(2, Int(value.rounded(.down)))
        return roundedDown - (roundedDown % 2)
    }
}
