#import "RuntimeObjectiveC.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static void helix_set_message(
    HelixRuntimeObjectiveCResult *result,
    NSString *message
) {
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding
                         allowLossyConversion:YES];
    if (data == nil) {
        data = [@"Objective-C invocation failed"
            dataUsingEncoding:NSUTF8StringEncoding];
    }
    const uint8_t *bytes = data.bytes;
    size_t count = MIN(data.length, sizeof(result->message) - 1);
    if (count < data.length) {
        // Back up to a UTF-8 scalar boundary if the fixed diagnostic buffer
        // would otherwise end in the middle of a multibyte sequence.
        while (count > 0 && (bytes[count] & 0xc0) == 0x80) {
            count -= 1;
        }
    }
    if (count > 0) {
        memcpy(result->message, bytes, count);
    }
    result->message[count] = '\0';
}

static NSString *helix_bounded_text(
    NSString *value,
    NSUInteger maximum_length,
    NSString *fallback
) {
    if (value == nil) {
        return fallback;
    }
    return value.length <= maximum_length
        ? value : [value substringToIndex:maximum_length];
}

static const char *helix_skip_qualifiers(const char *encoding) {
    if (encoding == NULL) {
        return NULL;
    }
    while (strchr("rnNoORV", *encoding) != NULL) {
        encoding += 1;
    }
    return encoding;
}

static bool helix_object_encoding_matches(
    const char *expected,
    const char *actual
) {
    if (expected[0] != '@' || actual[0] != '@') {
        return false;
    }
    if (expected[1] == '?') {
        return actual[1] == '?';
    }
    return actual[1] != '?';
}

static bool helix_encoding_matches(
    const char *expected_value,
    const char *actual_value
) {
    const char *expected = helix_skip_qualifiers(expected_value);
    const char *actual = helix_skip_qualifiers(actual_value);
    if (expected == NULL || actual == NULL || *expected == '\0' || *actual == '\0') {
        return false;
    }
    if (expected[0] == '@' || actual[0] == '@') {
        return helix_object_encoding_matches(expected, actual);
    }
    if (expected[0] == '^' && actual[0] == '^') {
        return helix_encoding_matches(expected + 1, actual + 1);
    }
    return strcmp(expected, actual) == 0;
}

static bool helix_argument_kind_matches(
    HelixRuntimeObjectiveCArgumentKind kind,
    const char *encoding_value
) {
    const char *encoding = helix_skip_qualifiers(encoding_value);
    if (encoding == NULL || *encoding == '\0') {
        return false;
    }
    switch (kind) {
        case HelixRuntimeObjectiveCArgumentBytes:
            return encoding[0] != '@' && encoding[0] != '^'
                && encoding[0] != '#' && encoding[0] != ':'
                && encoding[0] != 'v';
        case HelixRuntimeObjectiveCArgumentObject:
            return encoding[0] == '@' && encoding[1] != '?';
        case HelixRuntimeObjectiveCArgumentBlock:
            return encoding[0] == '@' && encoding[1] == '?';
        case HelixRuntimeObjectiveCArgumentErrorOut: {
            if (encoding[0] != '^') {
                return false;
            }
            const char *pointee = helix_skip_qualifiers(encoding + 1);
            return pointee != NULL && pointee[0] == '@' && pointee[1] != '?';
        }
    }
    return false;
}

static bool helix_result_kind_matches(
    HelixRuntimeObjectiveCResultKind kind,
    const char *encoding_value
) {
    const char *encoding = helix_skip_qualifiers(encoding_value);
    if (encoding == NULL || *encoding == '\0') {
        return false;
    }
    switch (kind) {
        case HelixRuntimeObjectiveCResultVoid:
            return encoding[0] == 'v';
        case HelixRuntimeObjectiveCResultObject:
            return encoding[0] == '@' && encoding[1] != '?';
        case HelixRuntimeObjectiveCResultBytes:
            return encoding[0] != 'v' && encoding[0] != '@'
                && encoding[0] != '^' && encoding[0] != '#'
                && encoding[0] != ':';
    }
    return false;
}

static NSMethodSignature *helix_signature(const char *encoding) {
    static NSCache<NSString *, NSMethodSignature *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    NSString *key = [NSString stringWithUTF8String:encoding];
    if (key == nil) {
        return nil;
    }
    NSMethodSignature *signature = [cache objectForKey:key];
    if (signature == nil) {
        signature = [NSMethodSignature signatureWithObjCTypes:encoding];
        if (signature != nil) {
            [cache setObject:signature forKey:key];
        }
    }
    return signature;
}

static bool helix_class_is_or_inherits_from(Class candidate, Class expected) {
    if (candidate == Nil || expected == Nil) {
        return false;
    }
    for (Class current = candidate; current != Nil;
         current = class_getSuperclass(current)) {
        if (current == expected) {
            return true;
        }
    }
    return false;
}

bool helix_runtime_objective_c_object_is_kind_of(
    void *object,
    const char *runtime_class_name
) {
    if (object == NULL || runtime_class_name == NULL) {
        return false;
    }
    Class expected = objc_getClass(runtime_class_name);
    return helix_class_is_or_inherits_from(
        object_getClass((__bridge id)object),
        expected
    );
}

bool helix_runtime_objective_c_object_conforms_to_protocol(
    void *object,
    const char *protocol_name
) {
    if (object == NULL || protocol_name == NULL) {
        return false;
    }
    Protocol *protocol = objc_getProtocol(protocol_name);
    if (protocol == nil) {
        return false;
    }
    for (Class current = object_getClass((__bridge id)object);
         current != Nil; current = class_getSuperclass(current)) {
        if (class_conformsToProtocol(current, protocol)) {
            return true;
        }
    }
    return false;
}

static bool helix_signatures_match(
    NSMethodSignature *expected,
    NSMethodSignature *actual
) {
    if (expected == nil || actual == nil
        || expected.numberOfArguments != actual.numberOfArguments
        || !helix_encoding_matches(
            expected.methodReturnType,
            actual.methodReturnType
        )) {
        return false;
    }
    for (NSUInteger index = 0; index < expected.numberOfArguments; index += 1) {
        if (!helix_encoding_matches(
                [expected getArgumentTypeAtIndex:index],
                [actual getArgumentTypeAtIndex:index]
            )) {
            return false;
        }
    }
    return true;
}

static Method helix_method(
    Class owner,
    Class declaration_class,
    SEL selector,
    HelixRuntimeObjectiveCDispatch dispatch
) {
    if (dispatch == HelixRuntimeObjectiveCDispatchClass) {
        return class_getClassMethod(owner, selector);
    }
    return class_getInstanceMethod(declaration_class, selector);
}

bool helix_runtime_objective_c_invoke(
    const char *declaration_class_name,
    const char *dispatch_class_name,
    const char *selector_name,
    const char *lexical_superclass_name,
    HelixRuntimeObjectiveCDispatch dispatch,
    bool returns_retained,
    void *receiver,
    const HelixRuntimeObjectiveCArgument *arguments,
    size_t argument_count,
    const char *result_encoding,
    HelixRuntimeObjectiveCResultKind result_kind,
    void *result_bytes,
    size_t result_capacity,
    HelixRuntimeObjectiveCResult *result
) {
    if (result == NULL) {
        return false;
    }
    memset(result, 0, sizeof(*result));
    result->status = HelixRuntimeObjectiveCStatusInvalidInput;
    if (declaration_class_name == NULL || selector_name == NULL
        || result_encoding == NULL || argument_count > 256
        || (argument_count > 0 && arguments == NULL)) {
        helix_set_message(result, @"Objective-C invocation input is incomplete");
        return false;
    }

    @autoreleasepool {
        void *allocated_target = NULL;
        @try {
            NSString *declaration_name = [NSString
                stringWithUTF8String:declaration_class_name];
            Class declaration_owner = declaration_name == nil
                ? Nil : NSClassFromString(declaration_name);
            if (declaration_owner == Nil) {
                result->status = HelixRuntimeObjectiveCStatusClassUnavailable;
                helix_set_message(result, @"cataloged Objective-C declaration class is unavailable");
                return false;
            }
            Class dispatch_owner = Nil;
            if (dispatch_class_name != NULL) {
                NSString *dispatch_name = [NSString
                    stringWithUTF8String:dispatch_class_name];
                dispatch_owner = dispatch_name == nil
                    ? Nil : NSClassFromString(dispatch_name);
            }
            bool needs_dispatch_owner = dispatch
                == HelixRuntimeObjectiveCDispatchClass
                || dispatch == HelixRuntimeObjectiveCDispatchInitializer;
            if (needs_dispatch_owner
                && (dispatch_owner == Nil
                    || !helix_class_is_or_inherits_from(
                        dispatch_owner,
                        declaration_owner
                    ))) {
                result->status = HelixRuntimeObjectiveCStatusClassUnavailable;
                helix_set_message(result, @"cataloged Objective-C dispatch class is unavailable or invalid");
                return false;
            }
            if (!needs_dispatch_owner && dispatch_class_name != NULL) {
                result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                helix_set_message(result, @"instance dispatch cannot name a dispatch class");
                return false;
            }
            SEL selector = sel_registerName(selector_name);
            __unsafe_unretained id target = nil;
            // The cataloged declaration class authorizes the selector and its
            // ABI. Invocation still targets the concrete receiver, preserving
            // ordinary Objective-C dynamic dispatch without trusting methods
            // that exist only on an unexpected runtime subclass.
            Class declaration_class = declaration_owner;
            IMP lexical_implementation = NULL;
            if (dispatch == HelixRuntimeObjectiveCDispatchClass) {
                target = dispatch_owner;
            } else if (dispatch == HelixRuntimeObjectiveCDispatchInitializer) {
                // Allocation is delayed until every catalog/runtime ABI check
                // has passed, so a rejected descriptor cannot leak an object.
                target = nil;
            } else {
                target = (__bridge id)receiver;
                if (target == nil || !helix_class_is_or_inherits_from(
                        object_getClass(target),
                        declaration_owner
                    )) {
                    result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                    helix_set_message(result, @"Objective-C receiver has the wrong class");
                    return false;
                }
            }

            if (lexical_superclass_name != NULL) {
                NSString *super_name = [NSString
                    stringWithUTF8String:lexical_superclass_name];
                Class lexical_superclass = super_name == nil
                    ? Nil : NSClassFromString(super_name);
                if (lexical_superclass == Nil
                    || !helix_class_is_or_inherits_from(
                        lexical_superclass,
                        declaration_owner
                    )
                    || !helix_class_is_or_inherits_from(
                        object_getClass(target),
                        lexical_superclass
                    )) {
                    result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                    helix_set_message(result, @"cataloged lexical superclass is invalid");
                    return false;
                }
                declaration_class = lexical_superclass;
            }

            Method method = helix_method(
                declaration_owner,
                declaration_class,
                selector,
                dispatch
            );
            if (method == NULL) {
                result->status = HelixRuntimeObjectiveCStatusSelectorUnavailable;
                helix_set_message(result, @"cataloged Objective-C selector is unavailable");
                return false;
            }
            if (lexical_superclass_name != NULL) {
                lexical_implementation = method_getImplementation(method);
                if (lexical_implementation == NULL) {
                    result->status = HelixRuntimeObjectiveCStatusSelectorUnavailable;
                    helix_set_message(result, @"lexical Objective-C implementation is unavailable");
                    return false;
                }
            }
            const char *method_encoding = method_getTypeEncoding(method);
            NSMethodSignature *signature = method_encoding == NULL
                ? nil : helix_signature(method_encoding);
            if (signature == nil || signature.numberOfArguments != argument_count + 2) {
                result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                helix_set_message(result, @"Objective-C method arity disagrees with its catalog");
                return false;
            }
            if (lexical_superclass_name == NULL) {
                Method dynamic_method = dispatch
                    == HelixRuntimeObjectiveCDispatchClass
                    ? class_getClassMethod(dispatch_owner, selector)
                    : class_getInstanceMethod(
                        dispatch == HelixRuntimeObjectiveCDispatchInitializer
                            ? dispatch_owner : object_getClass(target),
                        selector
                    );
                const char *dynamic_encoding = dynamic_method == NULL
                    ? NULL : method_getTypeEncoding(dynamic_method);
                NSMethodSignature *dynamic_signature = dynamic_encoding == NULL
                    ? nil : helix_signature(dynamic_encoding);
                if (!helix_signatures_match(signature, dynamic_signature)) {
                    result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                    helix_set_message(result, @"Objective-C override ABI disagrees with its declaration");
                    return false;
                }
            }
            if (!helix_encoding_matches(result_encoding, signature.methodReturnType)) {
                result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                helix_set_message(result, @"Objective-C return encoding disagrees with its catalog");
                return false;
            }
            if (!helix_result_kind_matches(result_kind, signature.methodReturnType)) {
                result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                helix_set_message(result, @"Objective-C return storage kind disagrees with its method encoding");
                return false;
            }

            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            NSError *__autoreleasing native_error = nil;
            for (size_t index = 0; index < argument_count; index += 1) {
                const HelixRuntimeObjectiveCArgument *argument = &arguments[index];
                const char *actual = [signature getArgumentTypeAtIndex:index + 2];
                if (!helix_encoding_matches(argument->encoding, actual)) {
                    result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                    helix_set_message(result, @"Objective-C parameter encoding disagrees with its catalog");
                    return false;
                }
                if (!helix_argument_kind_matches(argument->kind, actual)) {
                    result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                    helix_set_message(result, @"Objective-C parameter storage kind disagrees with its method encoding");
                    return false;
                }
                if (argument->kind == HelixRuntimeObjectiveCArgumentBytes) {
                    NSUInteger size = 0;
                    NSGetSizeAndAlignment(actual, &size, NULL);
                    if (argument->bytes == NULL || argument->byte_count != size) {
                        result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                        helix_set_message(result, @"Objective-C scalar or structure has the wrong size");
                        return false;
                    }
                    [invocation setArgument:(void *)argument->bytes atIndex:index + 2];
                } else if (argument->kind == HelixRuntimeObjectiveCArgumentObject
                    || argument->kind == HelixRuntimeObjectiveCArgumentBlock) {
                    id object = (__bridge id)argument->object;
                    [invocation setArgument:&object atIndex:index + 2];
                } else if (argument->kind == HelixRuntimeObjectiveCArgumentErrorOut) {
                    NSError *__autoreleasing *error_pointer = &native_error;
                    [invocation setArgument:&error_pointer atIndex:index + 2];
                } else {
                    result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                    helix_set_message(result, @"Objective-C argument kind is invalid");
                    return false;
                }
            }
            if (dispatch == HelixRuntimeObjectiveCDispatchInitializer) {
                // Transfer +alloc ownership out of ARC. Successful init-family
                // dispatch transfers that same +1 result across the C ABI;
                // an exception before the transfer is the only local release.
                allocated_target = (__bridge_retained void *)[dispatch_owner alloc];
                target = (__bridge id)allocated_target;
                if (target == nil) {
                    result->status = HelixRuntimeObjectiveCStatusInvocationFailure;
                    helix_set_message(result, @"Objective-C allocation returned nil");
                    return false;
                }
            }
            [invocation retainArguments];
            invocation.target = target;
            if (lexical_implementation != NULL) {
                [invocation invokeUsingIMP:lexical_implementation];
            } else {
                [invocation invoke];
            }
            if (dispatch == HelixRuntimeObjectiveCDispatchInitializer) {
                // A completed init-family call has consumed the +alloc
                // ownership, even when it returns nil or substitutes another
                // object. Do not release the original target if later result
                // extraction happens to raise an Objective-C exception.
                allocated_target = NULL;
            }

            if (native_error != nil) {
                result->retained_error = (__bridge_retained void *)native_error;
            }
            if (result_kind == HelixRuntimeObjectiveCResultVoid) {
                if (signature.methodReturnLength != 0) {
                    result->status = HelixRuntimeObjectiveCStatusSignatureMismatch;
                    helix_set_message(result, @"Objective-C method returned an unexpected value");
                    return false;
                }
            } else if (result_kind == HelixRuntimeObjectiveCResultObject) {
                __unsafe_unretained id returned = nil;
                [invocation getReturnValue:&returned];
                if (returned != nil) {
                    result->retained_object = returns_retained
                        ? (__bridge void *)returned
                        : (__bridge_retained void *)returned;
                }
            } else if (result_kind == HelixRuntimeObjectiveCResultBytes) {
                if (result_bytes == NULL
                    || signature.methodReturnLength == 0
                    || signature.methodReturnLength > result_capacity) {
                    result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                    helix_set_message(result, @"Objective-C result buffer is invalid");
                    return false;
                }
                [invocation getReturnValue:result_bytes];
                result->result_byte_count = signature.methodReturnLength;
            } else {
                result->status = HelixRuntimeObjectiveCStatusInvalidInput;
                helix_set_message(result, @"Objective-C result kind is invalid");
                return false;
            }
            result->status = HelixRuntimeObjectiveCStatusSuccess;
            return true;
        } @catch (NSException *exception) {
            if (allocated_target != NULL) {
                CFRelease(allocated_target);
            }
            result->status = HelixRuntimeObjectiveCStatusException;
            helix_set_message(
                result,
                [NSString stringWithFormat:@"Objective-C exception %@: %@",
                    helix_bounded_text(exception.name, 128, @"unknown"),
                    helix_bounded_text(exception.reason, 768, @"no reason")]
            );
            return false;
        }
    }
}
