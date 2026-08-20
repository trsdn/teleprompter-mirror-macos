#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around the private CoreGraphics virtual-display
/// API (`CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`,
/// `CGVirtualDisplayMode` and `CGVirtualDisplay`).
///
/// It synthesises an off-desktop display that hosts the teleprompter *source*
/// content. ScreenCaptureKit captures this display and the transformed image is
/// presented full-screen on a physical target display, so the source is never
/// occluded by the output.
///
/// The private classes are resolved with `NSClassFromString`, so the app links
/// no private symbols. When the API is unavailable the initialiser returns
/// `nil` and the caller must surface an error instead of crashing.
///
/// The receiver retains the underlying `CGVirtualDisplay` for its entire
/// lifetime; the synthetic display disappears as soon as this object is
/// deallocated, so it must be held for the lifetime of the app.
NS_SWIFT_NAME(VirtualDisplay)
@interface TPMVirtualDisplay : NSObject

/// The `CGDirectDisplayID` of the live virtual display.
@property (nonatomic, readonly) uint32_t displayID;

/// The pixel width of the preferred (first) virtual display mode.
@property (nonatomic, readonly) uint32_t pixelsWide;

/// The pixel height of the preferred (first) virtual display mode.
@property (nonatomic, readonly) uint32_t pixelsHigh;

/// Creates and activates a virtual display with a single preferred mode.
///
/// - Parameters:
///   - name: Human readable display name (for example `Teleprompter Source`).
///   - width: Mode width in pixels (for example `1920`).
///   - height: Mode height in pixels (for example `1080`).
///   - refreshRate: Mode refresh rate in hertz (for example `60`).
/// - Returns: `nil` when the private API is unavailable or activation fails.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
