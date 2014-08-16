// A dummy protocol to signal that a class should
// have its initializers created automatically
@protocol FAAutoInit <NSObject>
@optional
- (void)awakeFromInit;
@end
