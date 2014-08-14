#import <Foundation/Foundation.h>

@interface Klass : NSObject
@property int num;
@property id obj;
@property NSRect rect;
@end

@interface Klass (Initializers)
- (instancetype)initWithNum:(NSUInteger)aNum obj:(id)aObj rect:(NSRect)aRect;
@end

@implementation Klass
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Klass * const test = [[Klass alloc] initWithNum:123
                                                    obj:@456
                                                   rect:(NSRect) { {7,8},{9,10} }];
        NSLog(@"%@: %d %@ %@", test, (int)test.num, test.obj, NSStringFromRect(test.rect));
    }
}
