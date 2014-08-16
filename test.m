#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FAAutoInit.h"

@interface Klass : NSObject <FAAutoInit>
@property(readonly) int num;
@property(readonly, copy) id obj;
@property(readonly) CGRect rect;
@property(readonly) NSString *string;
@end

@interface Klass (Initializers)
+ (instancetype)klassWithNum:(int)aNum obj:(id)aObj rect:(CGRect)aRect string:(NSString *)aStr;
@end

@implementation Klass
@synthesize num=_number;
@dynamic string;

- (void)awakeFromInit
{
    NSLog(@"Initialized with %d%@%.f%.f%.f%.f%@",
          _number, _obj,
          _rect.origin.x, _rect.origin.y,
          _rect.size.width, _rect.size.height,
          self.string);
}

static NSString *foobar;
- (NSString *)string
{
    return foobar;
}
- (void)setString:(NSString *)aStr
{
    foobar = [aStr copy];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Klass * const test = [Klass klassWithNum:12 obj:@34 rect:(CGRect) { 5, 6, 7, 8 } string:@"!"];
        NSLog(@"%@", test);
    }
}
