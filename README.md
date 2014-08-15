# Automatic Initializers for Objective-C

This library adds to NSObject the ability to automatically derive initializers for properties.

## Usage:

Just link against `libautoinit.a` & libffi (Built in on OSX) with the `-ObjC` flag (If using Xcode you can specify it using "Other Linker Flags" under your target's build settings)

Then to in order for a class to have its initializers automatically created, make it conform to the protocol `FAAutoInit`.

## Example:

The example below should output `<Klass: 0x..>: 123 456 {{7, 8}, {9, 10}}`

```objc
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
```
