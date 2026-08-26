#import "RuntimeObjectiveCFixture.h"

#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

const char *HelixRuntimeTestBoolEncoding(void) {
    return @encode(BOOL);
}

const char *HelixRuntimeTestIntegerEncoding(void) {
    return @encode(NSInteger);
}

const char *HelixRuntimeTestUnsignedEncoding(void) {
    return @encode(NSUInteger);
}

const char *HelixRuntimeTestFloatEncoding(void) {
    return @encode(float);
}

const char *HelixRuntimeTestDoubleEncoding(void) {
    return @encode(double);
}

const char *HelixRuntimeTestPointEncoding(void) {
    return @encode(HelixRuntimeTestPoint);
}

// This intentionally models a hostile dynamic subclass that redeclares an
// inherited property with another accessor. The warning is the behavior under
// test, so keep its suppression scoped to this declaration.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wproperty-attribute-mismatch"
@interface HelixRuntimeTestRedirectingPropertyObject : HelixRuntimeTestObject
@property(nonatomic, assign, getter=helixRedirectedEnabled,
    setter=markEnabled:) BOOL enabled;
@end
#pragma clang diagnostic pop

@implementation HelixRuntimeTestRedirectingPropertyObject
@dynamic enabled;

- (BOOL)helixRedirectedEnabled {
    return NO;
}

@end

HelixRuntimeTestObject *HelixRuntimeTestMakeRedirectingPropertyObject(void) {
    HelixRuntimeTestRedirectingPropertyObject *object =
        [[HelixRuntimeTestRedirectingPropertyObject alloc] init];
    [object markEnabled:YES];
    return object;
}

BOOL HelixRuntimeTestRedirectingPropertyIsInstalled(void) {
    objc_property_t property = class_getProperty(
        HelixRuntimeTestRedirectingPropertyObject.class,
        "enabled"
    );
    if (property == NULL) {
        return NO;
    }
    char *getter = property_copyAttributeValue(property, "G");
    BOOL installed = getter != NULL
        && strcmp(getter, "helixRedirectedEnabled") == 0;
    free(getter);
    return installed;
}

@interface HelixRuntimeTestIncompatibleEchoObject : HelixRuntimeTestObject
@end

@implementation HelixRuntimeTestIncompatibleEchoObject
@end

static id helix_incompatible_echo(
    __unused id receiver,
    __unused SEL selector,
    __unused NSUInteger value
) {
    return @"incompatible";
}

HelixRuntimeTestObject *HelixRuntimeTestMakeIncompatibleEchoObject(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        class_addMethod(
            HelixRuntimeTestIncompatibleEchoObject.class,
            @selector(echo:),
            (IMP)helix_incompatible_echo,
            "@@:Q"
        );
    });
    return [[HelixRuntimeTestIncompatibleEchoObject alloc] init];
}

@implementation HelixRuntimeTestLyingObject

- (BOOL)isKindOfClass:(Class)aClass {
    (void)aClass;
    return YES;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    (void)aProtocol;
    return YES;
}

@end

@interface HelixRuntimeTestObject ()
@property(nonatomic, copy) void (^storedCallback)(BOOL value);
@end

@implementation HelixRuntimeTestObject

+ (NSInteger)addLeft:(NSInteger)left right:(NSInteger)right {
    return left + right;
}

+ (NSUInteger)addUnsignedLeft:(NSUInteger)left right:(NSUInteger)right {
    return left + right;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
    }
    return self;
}

- (instancetype)initReturningReplacement {
    return [[HelixRuntimeTestObject alloc] initWithName:@"replacement"];
}

- (NSString *)echo:(NSString *)value {
    return value;
}

- (nullable NSString *)nullableEcho:(nullable NSString *)value {
    return value;
}

- (NSString *)copyName {
    return [self.name copy];
}

- (void)recordString:(NSString *)value {
    (void)value;
    _invocationCount += 1;
}

- (void)recordNamingObject:(id<HelixRuntimeTestNaming>)object {
    (void)object.runtimeName;
    _invocationCount += 1;
}

- (float)scaleFloat:(float)value {
    return value * 2.0f;
}

- (double)scaleDouble:(double)value {
    return value * 2.0;
}

- (HelixRuntimeTestPoint)translatePoint:(HelixRuntimeTestPoint)point
                                      dx:(double)dx
                                      dy:(double)dy {
    return (HelixRuntimeTestPoint) {
        .x = point.x + dx,
        .y = point.y + dy,
    };
}

- (BOOL)failWithError:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"dev.helix.fixture"
                                     code:73
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"fixture failure",
        }];
    }
    return NO;
}

- (void)raiseFixtureException {
    [NSException raise:@"HelixFixtureException" format:@"fixture exception"];
}

- (void)callNow:(void (NS_NOESCAPE ^)(BOOL value))callback {
    callback(YES);
}

- (void)storeCallback:(void (^)(BOOL value))callback {
    self.storedCallback = callback;
}

- (void)triggerStoredCallback:(BOOL)value {
    if (self.storedCallback != nil) {
        self.storedCallback(value);
    }
}

- (void)callOptional:(void (NS_NOESCAPE ^ _Nullable)(BOOL value))callback {
    if (callback != nil) {
        callback(YES);
    }
}

- (void)callError:(void (NS_NOESCAPE ^)(NSError *error))callback {
    callback([NSError errorWithDomain:@"dev.helix.callback" code:17 userInfo:nil]);
}

- (BOOL)evaluateObject:(id)object
             predicate:(BOOL (NS_NOESCAPE ^)(id object))predicate {
    return predicate(object);
}

- (BOOL)evaluateLeft:(id)left
                right:(id)right
            predicate:(BOOL (NS_NOESCAPE ^)(id left, id right))predicate {
    return predicate(left, right);
}

@end

@implementation HelixRuntimeTestNamedObject
- (NSString *)runtimeName {
    return self.name ?: @"named";
}
@end

@implementation HelixRuntimeTestBase
+ (NSString *)classMarker {
    return @"base class";
}

- (NSString *)markerProperty {
    return @"base property";
}

- (NSString *)marker {
    return @"base";
}
@end


@implementation HelixRuntimeTestDerived
+ (NSString *)classMarker {
    return @"derived class";
}

- (NSString *)markerProperty {
    return @"derived property";
}

- (NSString *)marker {
    return @"derived";
}
@end
