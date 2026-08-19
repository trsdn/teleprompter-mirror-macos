import CoreGraphics
import Testing
@testable import TeleprompterCore

@Test("Layer geometry preserves transform order for every transform")
func layerGeometryPreservesTransformOrder() throws {
    let sourceSize = PixelSize(width: 160, height: 90)
    let targetBounds = CGRect(x: 17, y: 29, width: 120, height: 200)
    let sourceCorners = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 160, y: 0),
        CGPoint(x: 0, y: 90),
        CGPoint(x: 160, y: 90)
    ]

    for rotation in DisplayRotation.allCases {
        for mirrorHorizontally in [false, true] {
            for mirrorVertically in [false, true] {
                let transform = DisplayTransform(
                    rotation: rotation,
                    mirrorHorizontally: mirrorHorizontally,
                    mirrorVertically: mirrorVertically
                )
                let geometry = try #require(
                    TransformGeometry.layerPresentationGeometry(
                        sourceWidth: sourceSize.width,
                        sourceHeight: sourceSize.height,
                        targetBounds: targetBounds,
                        transform: transform
                    )
                )
                let fitted = TransformGeometry.aspectFitRectangle(
                    sourceWidth: sourceSize.width,
                    sourceHeight: sourceSize.height,
                    targetWidth: targetBounds.width,
                    targetHeight: targetBounds.height,
                    rotation: rotation
                )
                let expectedExtent = CGRect(
                    x: targetBounds.minX + fitted.x,
                    y: targetBounds.minY + fitted.y,
                    width: fitted.width,
                    height: fitted.height
                )

                expectRect(
                    geometry.presentedExtent,
                    equals: expectedExtent
                )

                let expectedUnitCorners = unitCornerDestinations(
                    rotation: rotation,
                    mirrorHorizontally: mirrorHorizontally,
                    mirrorVertically: mirrorVertically
                )
                for (sourceCorner, expectedUnitCorner) in zip(
                    sourceCorners,
                    expectedUnitCorners
                ) {
                    let actual = sourceCorner.applying(
                        geometry.affineTransform
                    )
                    let expected = CGPoint(
                        x: expectedExtent.minX
                            + expectedUnitCorner.x * expectedExtent.width,
                        y: expectedExtent.minY
                            + expectedUnitCorner.y * expectedExtent.height
                    )
                    expectPoint(actual, equals: expected)
                }
            }
        }
    }
}

@Test("Invalid layer geometry is rejected")
func invalidLayerGeometryIsRejected() {
    #expect(
        TransformGeometry.layerPresentationGeometry(
            sourceWidth: 0,
            sourceHeight: 90,
            targetBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            transform: .identity
        ) == nil
    )
    #expect(
        TransformGeometry.layerPresentationGeometry(
            sourceWidth: 160,
            sourceHeight: 90,
            targetBounds: .zero,
            transform: .identity
        ) == nil
    )
}

private func unitCornerDestinations(
    rotation: DisplayRotation,
    mirrorHorizontally: Bool,
    mirrorVertically: Bool
) -> [CGPoint] {
    let rotated: [CGPoint] = switch rotation {
    case .degrees0:
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1)
        ]
    case .degrees90:
        [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0)
        ]
    case .degrees180:
        [
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0)
        ]
    case .degrees270:
        [
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: 1)
        ]
    }

    return rotated.map { point in
        CGPoint(
            x: mirrorHorizontally ? 1 - point.x : point.x,
            y: mirrorVertically ? 1 - point.y : point.y
        )
    }
}

private func expectRect(
    _ actual: CGRect,
    equals expected: CGRect,
    tolerance: CGFloat = 0.0001
) {
    #expect(abs(actual.minX - expected.minX) < tolerance)
    #expect(abs(actual.minY - expected.minY) < tolerance)
    #expect(abs(actual.width - expected.width) < tolerance)
    #expect(abs(actual.height - expected.height) < tolerance)
}

private func expectPoint(
    _ actual: CGPoint,
    equals expected: CGPoint,
    tolerance: CGFloat = 0.0001
) {
    #expect(abs(actual.x - expected.x) < tolerance)
    #expect(abs(actual.y - expected.y) < tolerance)
}
