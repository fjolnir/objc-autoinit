#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FAAutoInit.h"

@interface Klass : NSObject <FAAutoInit>
@property(readonly) int num;
@property(readonly) id obj;
@property(readonly) CGRect rect;
@end

@interface Klass (Initializers)
+ (instancetype)klassWithNum:(int)aNum obj:(id)aObj rect:(CGRect)aRect;
@end

@implementation Klass
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Klass * const test = [Klass klassWithNum:123 obj:@456 rect:(CGRect) { {7,8},{9,10} }];
        NSLog(@"%@: %d %@ { %.f, %.f, %.f, %.f }",
              test, test.num, test.obj,
              test.rect.origin.x, test.rect.origin.y,
              test.rect.size.width, test.rect.size.height);
    }
}
