#import <Foundation/Foundation.h>
#import "FAAutoInit.h"

@interface Klass : NSObject <FAAutoInit>
@property(readonly) int num;
@property(readonly) id obj;
@property(readonly) NSRect rect;
@end

@interface Klass (Initializers)
+ (instancetype)klassWithNum:(int)aNum obj:(id)aObj rect:(NSRect)aRect;
@end

@implementation Klass
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Klass * const test = [Klass klassWithNum:123 obj:@456 rect:(NSRect) { {7,8},{9,10} }];
        NSLog(@"%@: %d %@ %@", test, (int)test.num, test.obj, NSStringFromRect(test.rect));
    }
}
