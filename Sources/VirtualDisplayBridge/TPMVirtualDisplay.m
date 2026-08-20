#import "TPMVirtualDisplay.h"

// ---------------------------------------------------------------------------
// Private CoreGraphics virtual-display API — declarations for typing only.
// The classes are instantiated with `NSClassFromString`, so no private symbol
// is linked. Layout mirrors the public technique used by BetterDummy and
// hidpi-mirror (https://github.com/pasky/hidpi-mirror/blob/master/hidpi-mirror.m).
// ---------------------------------------------------------------------------

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// Stable synthetic EDID-style identity. Keeping these constant lets the same
// persisted preset resolve the source across launches without ever colliding
// with real hardware. ("TM"/"VD" spell out Teleprompter Mirror / Virtual
// Display.)
static const unsigned int kTPMVendorID  = 0x544D; // "TM"
static const unsigned int kTPMProductID = 0x0001;
static const unsigned int kTPMSerialNum = 0x0001;
static const unsigned int kTPMMaxPixelsWide = 4096;
static const unsigned int kTPMMaxPixelsHigh = 2304;

@implementation TPMVirtualDisplay {
    // Held for the object's lifetime so the synthetic display stays online.
    id _virtualDisplay;
    id _descriptor;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (width == 0 || height == 0 || refreshRate <= 0) {
        return nil;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !settingsClass || !modeClass || !displayClass) {
        NSLog(@"[TPMVirtualDisplay] Private CGVirtualDisplay API unavailable.");
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    if (!descriptor) {
        NSLog(@"[TPMVirtualDisplay] Could not allocate display descriptor.");
        return nil;
    }

    descriptor.name = [name copy];
    descriptor.queue = dispatch_queue_create(
        "com.github.trsdn.TeleprompterMirror.virtualdisplay",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INTERACTIVE,
            0
        )
    );
    // A plausible 16:9 panel; only affects reported DPI, not capture.
    descriptor.sizeInMillimeters = CGSizeMake(476.0, 268.0);
    descriptor.maxPixelsWide = MAX(width, kTPMMaxPixelsWide);
    descriptor.maxPixelsHigh = MAX(height, kTPMMaxPixelsHigh);
    // sRGB primaries and a D65 white point.
    descriptor.redPrimary = CGPointMake(0.640, 0.330);
    descriptor.greenPrimary = CGPointMake(0.300, 0.600);
    descriptor.bluePrimary = CGPointMake(0.150, 0.060);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.vendorID = kTPMVendorID;
    descriptor.productID = kTPMProductID;
    descriptor.serialNum = kTPMSerialNum;
    descriptor.terminationHandler = ^(id sender, id info) {
        // The window server tore the display down (rare). Log only; the app's
        // run loop and reconnect logic decide what to do next. Never exit.
        NSLog(@"[TPMVirtualDisplay] Virtual display terminated by the system.");
    };

    CGVirtualDisplay *display =
        [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        NSLog(@"[TPMVirtualDisplay] Could not create the virtual display.");
        return nil;
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    CGVirtualDisplayMode *mode = [[modeClass alloc]
        initWithWidth:MAX(width / 2, 1)
               height:MAX(height / 2, 1)
                                                      refreshRate:refreshRate];
    if (!mode) {
        NSLog(@"[TPMVirtualDisplay] Could not create the display mode.");
        return nil;
    }
    settings.modes = @[mode];

    if (![display applySettings:settings]) {
        NSLog(@"[TPMVirtualDisplay] applySettings: failed.");
        return nil;
    }

    _virtualDisplay = display;
    _descriptor = descriptor;
    _displayID = display.displayID;
    _pixelsWide = width;
    _pixelsHigh = height;

    if (_displayID == 0) {
        NSLog(@"[TPMVirtualDisplay] Virtual display reported an invalid ID.");
        return nil;
    }

    NSLog(@"[TPMVirtualDisplay] Virtual display '%@' online: id=%u %ux%u@%.0f",
          name, _displayID, width, height, refreshRate);
    return self;
}

@end
