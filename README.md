# Automatic Initializers for Objective-C

This library adds to NSObject the ability to automatically derive initializers for properties.

## Usage:

Just link against `libautoinit.a` & libffi (Built in on OSX) with the `-ObjC` flag (If using Xcode you can specify it using "Other Linker Flags" under your target's build settings)

## Example:

The example below should output `<Klass: 0x..>: 123 456 {{7, 8}, {9, 10}}`

```objc
@interface Klass : NSObject
@property int number;
@property id object;
@property NSRect rect;
@end

@interface Klass (Initializers)
- (instancetype)initWithNumber:(NSUInteger)aNum object:(id)aObj rect:(NSRect)aRect;
@end

@implementation Klass
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Klass *test = [[Klass alloc] initWithNumber:123
                                             object:@456
                                               rect:(NSRect) { {7,8},{9,10} }];
        NSLog(@"%@: %d %@ %@", test, (int)test.num, test.obj, NSStringFromRect(test.rect));
    }
}
```