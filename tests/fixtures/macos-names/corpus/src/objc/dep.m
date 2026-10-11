// libobjcdep.dylib
#import "dep.h"
static int made;
@implementation XFThing {
    NSMutableArray<NSNumber *> *_log;
}
- (instancetype)initWithName:(NSString *)name
{
    if ((self = [super init])) {
        _name = [name copy];
        _log = [NSMutableArray array];
        _ratio = 0.25;
        made++;
    }
    return self;
}
- (NSArray<NSNumber *> *)history { return _log; }
- (int)bump
{
    [_log addObject:@(++_count)];
    if (_log.count > 8) [_log removeObjectAtIndex:0];
    return _count;
}
- (long)weigh { return _count * 2 + (long)_name.length; }
+ (int)made { return made; }
@end
@implementation XFThing (Extras)
- (NSString *)summary { return [NSString stringWithFormat:@"%@:%d", self.name, _count]; }
@end
