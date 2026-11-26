#import "EvantoDisplay.h"

// CoreGraphics provides these interfaces on current macOS without SDK headers.
// Resolve them at runtime so the window source also works on systems without them.
@protocol EVDisplayDescriptor
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@protocol EVDisplayMode
- (nullable instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol EVDisplaySettings
@property(nonatomic, strong) NSArray *modes;
@end

@protocol EVDisplayDevice
- (nullable instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(nonatomic, readonly) unsigned int displayID;
@end

static const uint32_t shareVendor = 0x4556;
static const uint32_t shareProduct = 0x5343;

static uint32_t availableSerial(void) {
    CGDirectDisplayID online[64];
    uint32_t count = 0;
    CGGetOnlineDisplayList(64, online, &count);
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    for (uint32_t i = 0; i < count; ++i) {
        if ([EVShareDisplay isShareDisplay:online[i]]) [used addIndex:CGDisplaySerialNumber(online[i])];
    }
    uint32_t serial = 1;
    while ([used containsIndex:serial]) ++serial;
    return serial;
}

@implementation EVShareDisplay {
    id<EVDisplayDevice> _device;
}

- (nullable instancetype)initWithName:(NSString *)name width:(uint32_t)width height:(uint32_t)height {
    self = [super init];
    if (!self || !width || !height) return nil;
    @try {
        id<EVDisplayDescriptor> descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
        id<EVDisplaySettings> settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
        id<EVDisplayMode> mode = [(id<EVDisplayMode>)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
            initWithWidth:width height:height refreshRate:60];
        if (!descriptor || !settings || !mode) return nil;
        descriptor.name = name;
        descriptor.vendorID = shareVendor;
        descriptor.productID = shareProduct;
        uint32_t serial = availableSerial();
        descriptor.serialNum = serial;
        descriptor.serialNumber = serial;
        descriptor.queue = dispatch_get_main_queue();
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 96, height * 25.4 / 96);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        descriptor.redPrimary = CGPointMake(0.640, 0.330);
        descriptor.greenPrimary = CGPointMake(0.300, 0.600);
        descriptor.bluePrimary = CGPointMake(0.150, 0.060);
        settings.modes = @[mode];
        id<EVDisplayDevice> device = [(id<EVDisplayDevice>)[NSClassFromString(@"CGVirtualDisplay") alloc]
            initWithDescriptor:descriptor];
        if (!device || ![device applySettings:settings] || !device.displayID) return nil;
        _device = device;
        return self;
    } @catch (NSException *exception) {
        NSLog(@"Evanto could not create a share display: %@", exception.reason);
        return nil;
    }
}

- (CGDirectDisplayID)displayID { return _device.displayID; }

+ (BOOL)isShareDisplay:(CGDirectDisplayID)displayID {
    return CGDisplayVendorNumber(displayID) == shareVendor && CGDisplayModelNumber(displayID) == shareProduct;
}
@end
