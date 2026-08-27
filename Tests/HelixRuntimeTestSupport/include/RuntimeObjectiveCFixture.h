#ifndef HELIX_RUNTIME_OBJECTIVE_C_FIXTURE_H
#define HELIX_RUNTIME_OBJECTIVE_C_FIXTURE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double x;
    double y;
} HelixRuntimeTestPoint;

@protocol HelixRuntimeTestNaming <NSObject>
- (NSString *)runtimeName;
@end

FOUNDATION_EXPORT const char *HelixRuntimeTestBoolEncoding(void);
FOUNDATION_EXPORT const char *HelixRuntimeTestIntegerEncoding(void);
FOUNDATION_EXPORT const char *HelixRuntimeTestUnsignedEncoding(void);
FOUNDATION_EXPORT const char *HelixRuntimeTestFloatEncoding(void);
FOUNDATION_EXPORT const char *HelixRuntimeTestDoubleEncoding(void);
FOUNDATION_EXPORT const char *HelixRuntimeTestPointEncoding(void);

FOUNDATION_EXPORT int64_t HelixRuntimeTestCAdd64(int64_t left, int64_t right);
FOUNDATION_EXPORT double HelixRuntimeTestCMultiplyDouble(
    double left,
    double right
);
FOUNDATION_EXPORT CGRect HelixRuntimeTestCMakeRect(
    double x,
    double y,
    double width,
    double height
);
FOUNDATION_EXPORT BOOL HelixRuntimeTestCRectContainsPoint(
    CGRect rect,
    CGPoint point
);
FOUNDATION_EXPORT CGPoint HelixRuntimeTestCApplyPointTransform(
    CGPoint point,
    CGAffineTransform transform
);

@interface HelixRuntimeTestObject : NSObject

@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign, getter=isEnabled, setter=markEnabled:) BOOL enabled;
@property(nonatomic, assign, readonly) NSUInteger invocationCount;

+ (NSInteger)addLeft:(NSInteger)left right:(NSInteger)right;
+ (NSUInteger)addUnsignedLeft:(NSUInteger)left right:(NSUInteger)right;
- (instancetype)initWithName:(NSString *)name;
- (instancetype)initReturningReplacement;
- (NSString *)echo:(NSString *)value;
- (nullable NSString *)nullableEcho:(nullable NSString *)value;
- (NSString *)copyName;
- (void)recordString:(NSString *)value;
- (void)recordNamingObject:(id<HelixRuntimeTestNaming>)object;
- (id)identityObject:(id)object;
- (float)scaleFloat:(float)value;
- (double)scaleDouble:(double)value;
- (HelixRuntimeTestPoint)translatePoint:(HelixRuntimeTestPoint)point
                                      dx:(double)dx
                                      dy:(double)dy;
- (BOOL)failWithError:(NSError * _Nullable * _Nullable)error;
- (void)raiseFixtureException;
- (void)callNow:(void (NS_NOESCAPE ^)(BOOL value))callback;
- (void)storeCallback:(void (^)(BOOL value))callback;
- (void)triggerStoredCallback:(BOOL)value;
- (void)callOptional:(void (NS_NOESCAPE ^ _Nullable)(BOOL value))callback;
- (void)callError:(void (NS_NOESCAPE ^)(NSError *error))callback;
- (BOOL)evaluateObject:(id)object
             predicate:(BOOL (NS_NOESCAPE ^)(id object))predicate;
- (BOOL)evaluateLeft:(id)left
                right:(id)right
            predicate:(BOOL (NS_NOESCAPE ^)(id left, id right))predicate;

@end

FOUNDATION_EXPORT HelixRuntimeTestObject *
    HelixRuntimeTestMakeRedirectingPropertyObject(void);
FOUNDATION_EXPORT BOOL HelixRuntimeTestRedirectingPropertyIsInstalled(void);
FOUNDATION_EXPORT HelixRuntimeTestObject *
    HelixRuntimeTestMakeIncompatibleEchoObject(void);

/// Deliberately lies through NSObject's dynamic query. Runtime tests use this
/// to prove native invocation checks the actual class hierarchy instead.
@interface HelixRuntimeTestLyingObject : NSObject
@end

@interface HelixRuntimeTestNamedObject : HelixRuntimeTestObject <HelixRuntimeTestNaming>
@end

@interface HelixRuntimeTestBase : NSObject
@property(nonatomic, readonly) NSString *markerProperty;
+ (NSString *)classMarker;
- (NSString *)marker;
@end

@interface HelixRuntimeTestDerived : HelixRuntimeTestBase
@property(nonatomic, readonly) NSString *markerProperty;
+ (NSString *)classMarker;
- (NSString *)marker;
@end

NS_ASSUME_NONNULL_END

#endif
