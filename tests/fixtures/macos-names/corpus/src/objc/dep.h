// Shared declarations for the owned corpus fixture (Objective-C).
#import <Foundation/Foundation.h>
@protocol XFWeighing
- (long)weigh;
@end
@interface XFThing : NSObject <XFWeighing> {
    int _count;
@public
    double _ratio;
}
@property(nonatomic, copy) NSString *name;
@property(nonatomic, readonly) NSArray<NSNumber *> *history;
- (instancetype)initWithName:(NSString *)name;
- (int)bump;
+ (int)made;
@end
@interface XFThing (Extras)
- (NSString *)summary;
@end
