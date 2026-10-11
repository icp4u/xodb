// objcprog: owned Objective-C fixture. Prints its pid and loops through bp_target.
#import <stdio.h>
#import <unistd.h>
#import "dep.h"
volatile unsigned long objc_marker = 0x6f626a63;
__attribute__((noinline)) void bp_target(long total) { objc_marker += (unsigned long)total; __asm__ volatile("" ::: "memory"); }
int main(void)
{
    setvbuf(stdout, 0, _IONBF, 0);
    @autoreleasepool {
        XFThing *thing = [[XFThing alloc] initWithName:@"thing"];
        NSDictionary<NSString *, id> *table = @{@"thing": thing, @"limit": @9};
        long (^scale)(long) = ^(long value) { return value * [table[@"limit"] longValue]; };
        printf("pid=%d\nbp_target=%p\nobjc_marker=%p\nready\n", (int)getpid(), (void *)bp_target, (void *)&objc_marker);
        for (;;) {
            @autoreleasepool {
                long total = scale([thing bump]) + [thing weigh] + (long)[thing summary].length;
                bp_target(total);
            }
            usleep(1000);
        }
    }
}
