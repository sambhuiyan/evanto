#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EVShareDisplay : NSObject
- (nullable instancetype)initWithName:(NSString *)name width:(uint32_t)width height:(uint32_t)height;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (BOOL)isShareDisplay:(CGDirectDisplayID)displayID;
@end

NS_ASSUME_NONNULL_END
