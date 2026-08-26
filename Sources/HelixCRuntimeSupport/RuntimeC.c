#include "RuntimeC.h"

#include <CoreGraphics/CoreGraphics.h>
#include <string.h>

static void helix_c_set_message(
    HelixRuntimeCResult *result,
    const char *message
) {
    size_t count = strlen(message);
    if (count >= sizeof(result->message)) {
        count = sizeof(result->message) - 1;
    }
    if (count > 0) {
        memcpy(result->message, message, count);
    }
    result->message[count] = '\0';
}

static bool helix_c_encoding_is(const char *value, const char *expected) {
    return value != NULL && strcmp(value, expected) == 0;
}

static size_t helix_c_encoding_size(const char *encoding) {
    if (encoding == NULL) {
        return 0;
    }
    if (strcmp(encoding, "B") == 0
        || strcmp(encoding, "c") == 0
        || strcmp(encoding, "C") == 0) {
        return 1;
    }
    if (strcmp(encoding, "s") == 0 || strcmp(encoding, "S") == 0) {
        return 2;
    }
    if (strcmp(encoding, "i") == 0 || strcmp(encoding, "I") == 0
        || strcmp(encoding, "f") == 0) {
        return 4;
    }
    if (strcmp(encoding, "q") == 0 || strcmp(encoding, "Q") == 0
        || strcmp(encoding, "d") == 0) {
        return 8;
    }
    if (strcmp(encoding, "{CGPoint=dd}") == 0) {
        return sizeof(CGPoint);
    }
    if (strcmp(encoding, "{CGSize=dd}") == 0) {
        return sizeof(CGSize);
    }
    if (strcmp(encoding, "{CGVector=dd}") == 0) {
        return sizeof(CGVector);
    }
    if (strcmp(encoding, "{CGRect={CGPoint=dd}{CGSize=dd}}") == 0) {
        return sizeof(CGRect);
    }
    if (strcmp(encoding, "{CGAffineTransform=dddddd}") == 0) {
        return sizeof(CGAffineTransform);
    }
    return 0;
}

static bool helix_c_all_arguments_are(
    const char *const *encodings,
    size_t count,
    const char *encoding
) {
    for (size_t index = 0; index < count; index += 1) {
        if (!helix_c_encoding_is(encodings[index], encoding)) {
            return false;
        }
    }
    return true;
}

static bool helix_c_homogeneous_scalar_signature(
    const char *const *arguments,
    size_t argument_count,
    const char *result
) {
    static const char *const encodings[] = {
        "B", "c", "C", "s", "S", "i", "I", "q", "Q", "f", "d",
    };
    if (argument_count > 4) {
        return false;
    }
    for (size_t index = 0;
         index < sizeof(encodings) / sizeof(encodings[0]); index += 1) {
        const char *encoding = encodings[index];
        if (helix_c_all_arguments_are(arguments, argument_count, encoding)
            && (helix_c_encoding_is(result, encoding)
                || helix_c_encoding_is(result, "v"))) {
            return true;
        }
    }
    return false;
}

static bool helix_c_struct_signature(
    const char *const *arguments,
    size_t argument_count,
    const char *result
) {
    const char *point = "{CGPoint=dd}";
    const char *size = "{CGSize=dd}";
    const char *vector = "{CGVector=dd}";
    const char *rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";
    const char *transform = "{CGAffineTransform=dddddd}";
    if (argument_count == 2
        && helix_c_all_arguments_are(arguments, 2, "d")
        && (helix_c_encoding_is(result, point)
            || helix_c_encoding_is(result, size)
            || helix_c_encoding_is(result, vector))) {
        return true;
    }
    if (argument_count == 4
        && helix_c_all_arguments_are(arguments, 4, "d")
        && helix_c_encoding_is(result, rect)) {
        return true;
    }
    if (argument_count == 6
        && helix_c_all_arguments_are(arguments, 6, "d")
        && helix_c_encoding_is(result, transform)) {
        return true;
    }
    if (argument_count == 1 && helix_c_encoding_is(result, "d")
        && (helix_c_encoding_is(arguments[0], point)
            || helix_c_encoding_is(arguments[0], size)
            || helix_c_encoding_is(arguments[0], vector)
            || helix_c_encoding_is(arguments[0], rect))) {
        return true;
    }
    if (argument_count == 2 && helix_c_encoding_is(result, "B")
        && ((helix_c_encoding_is(arguments[0], rect)
                && helix_c_encoding_is(arguments[1], point))
            || (helix_c_encoding_is(arguments[0], rect)
                && helix_c_encoding_is(arguments[1], rect)))) {
        return true;
    }
    if (argument_count == 2
        && helix_c_encoding_is(arguments[0], rect)
        && helix_c_encoding_is(arguments[1], rect)
        && helix_c_encoding_is(result, rect)) {
        return true;
    }
    if (argument_count == 2
        && helix_c_encoding_is(arguments[1], transform)
        && ((helix_c_encoding_is(arguments[0], point)
                && helix_c_encoding_is(result, point))
            || (helix_c_encoding_is(arguments[0], size)
                && helix_c_encoding_is(result, size))
            || (helix_c_encoding_is(arguments[0], rect)
                && helix_c_encoding_is(result, rect)))) {
        return true;
    }
    return argument_count == 2
        && helix_c_encoding_is(arguments[0], transform)
        && helix_c_encoding_is(arguments[1], transform)
        && helix_c_encoding_is(result, transform);
}

bool helix_runtime_c_signature_is_supported(
    const char *const *argument_encodings,
    size_t argument_count,
    const char *result_encoding
) {
    if (result_encoding == NULL || argument_count > 6
        || (argument_count > 0 && argument_encodings == NULL)) {
        return false;
    }
    if (argument_count == 0 && helix_c_encoding_is(result_encoding, "v")) {
        return true;
    }
    return helix_c_homogeneous_scalar_signature(
        argument_encodings,
        argument_count,
        result_encoding
    ) || helix_c_struct_signature(
        argument_encodings,
        argument_count,
        result_encoding
    );
}

#define HELIX_C_LOAD(type, index) (*(const type *)arguments[index].bytes)
#define HELIX_C_STORE(value) do { \
    if (result_bytes == NULL || result_capacity < sizeof(value)) { \
        result->status = HelixRuntimeCStatusInvalidInput; \
        helix_c_set_message(result, "C result buffer is too small"); \
        return false; \
    } \
    memcpy(result_bytes, &(value), sizeof(value)); \
    result->result_byte_count = sizeof(value); \
    result->status = HelixRuntimeCStatusSuccess; \
    return true; \
} while (0)

#define HELIX_C_INVOKE_HOMOGENEOUS(type, code) do { \
    if (helix_c_all_arguments_are(encodings, argument_count, code)) { \
        if (helix_c_encoding_is(result_encoding, code)) { \
            type value; \
            switch (argument_count) { \
                case 0: value = ((type (*)(void))function)(); break; \
                case 1: value = ((type (*)(type))function)( \
                    HELIX_C_LOAD(type, 0)); break; \
                case 2: value = ((type (*)(type, type))function)( \
                    HELIX_C_LOAD(type, 0), HELIX_C_LOAD(type, 1)); break; \
                case 3: value = ((type (*)(type, type, type))function)( \
                    HELIX_C_LOAD(type, 0), HELIX_C_LOAD(type, 1), \
                    HELIX_C_LOAD(type, 2)); break; \
                case 4: value = ((type (*)(type, type, type, type))function)( \
                    HELIX_C_LOAD(type, 0), HELIX_C_LOAD(type, 1), \
                    HELIX_C_LOAD(type, 2), HELIX_C_LOAD(type, 3)); break; \
                default: break; \
            } \
            HELIX_C_STORE(value); \
        } \
        if (helix_c_encoding_is(result_encoding, "v")) { \
            switch (argument_count) { \
                case 1: ((void (*)(type))function)( \
                    HELIX_C_LOAD(type, 0)); break; \
                case 2: ((void (*)(type, type))function)( \
                    HELIX_C_LOAD(type, 0), HELIX_C_LOAD(type, 1)); break; \
                case 3: ((void (*)(type, type, type))function)( \
                    HELIX_C_LOAD(type, 0), HELIX_C_LOAD(type, 1), \
                    HELIX_C_LOAD(type, 2)); break; \
                case 4: ((void (*)(type, type, type, type))function)( \
                    HELIX_C_LOAD(type, 0), HELIX_C_LOAD(type, 1), \
                    HELIX_C_LOAD(type, 2), HELIX_C_LOAD(type, 3)); break; \
                default: break; \
            } \
            result->status = HelixRuntimeCStatusSuccess; \
            return true; \
        } \
    } \
} while (0)

bool helix_runtime_c_invoke(
    const void *function,
    const HelixRuntimeCArgument *arguments,
    size_t argument_count,
    const char *result_encoding,
    void *result_bytes,
    size_t result_capacity,
    HelixRuntimeCResult *result
) {
    if (result == NULL) {
        return false;
    }
    memset(result, 0, sizeof(*result));
    result->status = HelixRuntimeCStatusInvalidInput;
    if (function == NULL || result_encoding == NULL || argument_count > 6
        || (argument_count > 0 && arguments == NULL)) {
        helix_c_set_message(result, "C invocation input is incomplete");
        return false;
    }
    const char *encodings[6] = {0};
    for (size_t index = 0; index < argument_count; index += 1) {
        size_t expected_size = helix_c_encoding_size(arguments[index].encoding);
        if (expected_size == 0 || arguments[index].bytes == NULL
            || arguments[index].byte_count != expected_size) {
            helix_c_set_message(result, "C argument storage disagrees with its encoding");
            return false;
        }
        encodings[index] = arguments[index].encoding;
    }
    if (!helix_runtime_c_signature_is_supported(
            encodings,
            argument_count,
            result_encoding
        )) {
        result->status = HelixRuntimeCStatusUnsupportedSignature;
        helix_c_set_message(result, "C ABI shape has no AOT trampoline");
        return false;
    }
    if (argument_count == 0 && helix_c_encoding_is(result_encoding, "v")) {
        ((void (*)(void))function)();
        result->status = HelixRuntimeCStatusSuccess;
        return true;
    }

    HELIX_C_INVOKE_HOMOGENEOUS(bool, "B");
    HELIX_C_INVOKE_HOMOGENEOUS(int8_t, "c");
    HELIX_C_INVOKE_HOMOGENEOUS(uint8_t, "C");
    HELIX_C_INVOKE_HOMOGENEOUS(int16_t, "s");
    HELIX_C_INVOKE_HOMOGENEOUS(uint16_t, "S");
    HELIX_C_INVOKE_HOMOGENEOUS(int32_t, "i");
    HELIX_C_INVOKE_HOMOGENEOUS(uint32_t, "I");
    HELIX_C_INVOKE_HOMOGENEOUS(int64_t, "q");
    HELIX_C_INVOKE_HOMOGENEOUS(uint64_t, "Q");
    HELIX_C_INVOKE_HOMOGENEOUS(float, "f");
    HELIX_C_INVOKE_HOMOGENEOUS(double, "d");

    if (argument_count == 2
        && helix_c_all_arguments_are(encodings, 2, "d")) {
        double first = HELIX_C_LOAD(double, 0);
        double second = HELIX_C_LOAD(double, 1);
        if (helix_c_encoding_is(result_encoding, "{CGPoint=dd}")) {
            CGPoint value = ((CGPoint (*)(double, double))function)(first, second);
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(result_encoding, "{CGSize=dd}")) {
            CGSize value = ((CGSize (*)(double, double))function)(first, second);
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(result_encoding, "{CGVector=dd}")) {
            CGVector value = ((CGVector (*)(double, double))function)(first, second);
            HELIX_C_STORE(value);
        }
    }
    if (argument_count == 4
        && helix_c_all_arguments_are(encodings, 4, "d")
        && helix_c_encoding_is(
            result_encoding,
            "{CGRect={CGPoint=dd}{CGSize=dd}}"
        )) {
        CGRect value = ((CGRect (*)(double, double, double, double))function)(
            HELIX_C_LOAD(double, 0), HELIX_C_LOAD(double, 1),
            HELIX_C_LOAD(double, 2), HELIX_C_LOAD(double, 3)
        );
        HELIX_C_STORE(value);
    }
    if (argument_count == 6
        && helix_c_all_arguments_are(encodings, 6, "d")
        && helix_c_encoding_is(result_encoding, "{CGAffineTransform=dddddd}")) {
        CGAffineTransform value = ((CGAffineTransform (*)(
            double, double, double, double, double, double
        ))function)(
            HELIX_C_LOAD(double, 0), HELIX_C_LOAD(double, 1),
            HELIX_C_LOAD(double, 2), HELIX_C_LOAD(double, 3),
            HELIX_C_LOAD(double, 4), HELIX_C_LOAD(double, 5)
        );
        HELIX_C_STORE(value);
    }
    if (argument_count == 1 && helix_c_encoding_is(result_encoding, "d")) {
        double value;
        if (helix_c_encoding_is(encodings[0], "{CGPoint=dd}")) {
            value = ((double (*)(CGPoint))function)(HELIX_C_LOAD(CGPoint, 0));
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(encodings[0], "{CGSize=dd}")) {
            value = ((double (*)(CGSize))function)(HELIX_C_LOAD(CGSize, 0));
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(encodings[0], "{CGVector=dd}")) {
            value = ((double (*)(CGVector))function)(HELIX_C_LOAD(CGVector, 0));
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(
                encodings[0],
                "{CGRect={CGPoint=dd}{CGSize=dd}}"
            )) {
            value = ((double (*)(CGRect))function)(HELIX_C_LOAD(CGRect, 0));
            HELIX_C_STORE(value);
        }
    }
    if (argument_count == 2
        && helix_c_encoding_is(
            encodings[0],
            "{CGRect={CGPoint=dd}{CGSize=dd}}"
        )) {
        CGRect first = HELIX_C_LOAD(CGRect, 0);
        if (helix_c_encoding_is(encodings[1], "{CGPoint=dd}")
            && helix_c_encoding_is(result_encoding, "B")) {
            bool value = ((bool (*)(CGRect, CGPoint))function)(
                first,
                HELIX_C_LOAD(CGPoint, 1)
            );
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(
                encodings[1],
                "{CGRect={CGPoint=dd}{CGSize=dd}}"
            )) {
            CGRect second = HELIX_C_LOAD(CGRect, 1);
            if (helix_c_encoding_is(result_encoding, "B")) {
                bool value = ((bool (*)(CGRect, CGRect))function)(first, second);
                HELIX_C_STORE(value);
            }
            if (helix_c_encoding_is(
                    result_encoding,
                    "{CGRect={CGPoint=dd}{CGSize=dd}}"
                )) {
                CGRect value = ((CGRect (*)(CGRect, CGRect))function)(first, second);
                HELIX_C_STORE(value);
            }
        }
    }
    if (argument_count == 2
        && helix_c_encoding_is(encodings[1], "{CGAffineTransform=dddddd}")) {
        CGAffineTransform transform = HELIX_C_LOAD(CGAffineTransform, 1);
        if (helix_c_encoding_is(encodings[0], "{CGPoint=dd}")
            && helix_c_encoding_is(result_encoding, "{CGPoint=dd}")) {
            CGPoint value = ((CGPoint (*)(CGPoint, CGAffineTransform))function)(
                HELIX_C_LOAD(CGPoint, 0), transform
            );
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(encodings[0], "{CGSize=dd}")
            && helix_c_encoding_is(result_encoding, "{CGSize=dd}")) {
            CGSize value = ((CGSize (*)(CGSize, CGAffineTransform))function)(
                HELIX_C_LOAD(CGSize, 0), transform
            );
            HELIX_C_STORE(value);
        }
        if (helix_c_encoding_is(
                encodings[0],
                "{CGRect={CGPoint=dd}{CGSize=dd}}"
            ) && helix_c_encoding_is(
                result_encoding,
                "{CGRect={CGPoint=dd}{CGSize=dd}}"
            )) {
            CGRect value = ((CGRect (*)(CGRect, CGAffineTransform))function)(
                HELIX_C_LOAD(CGRect, 0), transform
            );
            HELIX_C_STORE(value);
        }
    }
    if (argument_count == 2
        && helix_c_encoding_is(encodings[0], "{CGAffineTransform=dddddd}")
        && helix_c_encoding_is(encodings[1], "{CGAffineTransform=dddddd}")
        && helix_c_encoding_is(result_encoding, "{CGAffineTransform=dddddd}")) {
        CGAffineTransform value = ((CGAffineTransform (*)(
            CGAffineTransform,
            CGAffineTransform
        ))function)(
            HELIX_C_LOAD(CGAffineTransform, 0),
            HELIX_C_LOAD(CGAffineTransform, 1)
        );
        HELIX_C_STORE(value);
    }

    result->status = HelixRuntimeCStatusInvocationFailure;
    helix_c_set_message(result, "C trampoline selection failed after validation");
    return false;
}
