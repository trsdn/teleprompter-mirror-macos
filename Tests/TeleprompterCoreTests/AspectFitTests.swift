import Testing
@testable import TeleprompterCore

@Test("A wide source is letterboxed above and below")
func wideSourceIsLetterboxed() {
    let scale = AspectFit.scale(
        sourceWidth: 1920,
        sourceHeight: 1080,
        targetWidth: 1024,
        targetHeight: 768
    )

    #expect(scale.x == 1)
    #expect(abs(scale.y - 0.75) < 0.0001)
}

@Test("A narrow source is pillarboxed")
func narrowSourceIsPillarboxed() {
    let scale = AspectFit.scale(
        sourceWidth: 1024,
        sourceHeight: 768,
        targetWidth: 1920,
        targetHeight: 1080
    )

    #expect(abs(scale.x - 0.75) < 0.0001)
    #expect(scale.y == 1)
}

@Test("Invalid dimensions produce an empty rectangle")
func invalidDimensionsAreEmpty() {
    let scale = AspectFit.scale(
        sourceWidth: 0,
        sourceHeight: 1080,
        targetWidth: 1920,
        targetHeight: 1080
    )

    #expect(scale == AspectFitScale(x: 0, y: 0))
}

@Test("Capture size is bounded by target dimension")
func captureSizeIsBounded() {
    let size = CaptureSizing.fitted(
        sourceWidth: 5120,
        sourceHeight: 1440,
        maximumDimension: 1920
    )

    #expect(size == PixelDimensions(width: 1920, height: 540))
}

@Test("Capture sizing preserves portrait orientation")
func captureSizingPreservesPortraitOrientation() {
    let size = CaptureSizing.fitted(
        sourceWidth: 1440,
        sourceHeight: 5120,
        maximumDimension: 1920
    )

    #expect(size == PixelDimensions(width: 540, height: 1920))
}

@Test("Capture sizing never upscales")
func captureSizingNeverUpscales() {
    let size = CaptureSizing.fitted(
        sourceWidth: 1280,
        sourceHeight: 720,
        maximumDimension: 1920
    )

    #expect(size == PixelDimensions(width: 1280, height: 720))
}
