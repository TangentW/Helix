#ifndef HELIX_RUNTIME_OBJECTIVE_C_H
#define HELIX_RUNTIME_OBJECTIVE_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef enum : uint8_t {
    HelixRuntimeObjectiveCArgumentBytes = 0,
    HelixRuntimeObjectiveCArgumentObject = 1,
    HelixRuntimeObjectiveCArgumentBlock = 2,
    HelixRuntimeObjectiveCArgumentErrorOut = 3,
} HelixRuntimeObjectiveCArgumentKind;

typedef enum : uint8_t {
    HelixRuntimeObjectiveCDispatchInstance = 0,
    HelixRuntimeObjectiveCDispatchClass = 1,
    HelixRuntimeObjectiveCDispatchInitializer = 2,
} HelixRuntimeObjectiveCDispatch;

typedef enum : uint8_t {
    HelixRuntimeObjectiveCResultVoid = 0,
    HelixRuntimeObjectiveCResultBytes = 1,
    HelixRuntimeObjectiveCResultObject = 2,
} HelixRuntimeObjectiveCResultKind;

typedef enum : uint8_t {
    HelixRuntimeObjectiveCStatusSuccess = 0,
    HelixRuntimeObjectiveCStatusInvalidInput = 1,
    HelixRuntimeObjectiveCStatusClassUnavailable = 2,
    HelixRuntimeObjectiveCStatusSelectorUnavailable = 3,
    HelixRuntimeObjectiveCStatusSignatureMismatch = 4,
    HelixRuntimeObjectiveCStatusException = 5,
    HelixRuntimeObjectiveCStatusInvocationFailure = 6,
} HelixRuntimeObjectiveCStatus;

typedef struct {
    const char *encoding;
    const void *bytes;
    size_t byte_count;
    void *object;
    HelixRuntimeObjectiveCArgumentKind kind;
} HelixRuntimeObjectiveCArgument;

enum { HelixRuntimeObjectiveCMessageCapacity = 1024 };

typedef struct {
    HelixRuntimeObjectiveCStatus status;
    void *retained_object;
    void *retained_error;
    size_t result_byte_count;
    char message[HelixRuntimeObjectiveCMessageCapacity];
} HelixRuntimeObjectiveCResult;

/// Performs class/protocol checks from immutable runtime metadata rather than
/// sending overridable introspection messages to the object.
bool helix_runtime_objective_c_object_is_kind_of(
    void *object,
    const char *runtime_class_name
);

bool helix_runtime_objective_c_object_conforms_to_protocol(
    void *object,
    const char *protocol_name
);

/// Executes only the supplied, already-cataloged class/selector/signature.
/// Object results are returned at +1 and must be consumed exactly once.
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
);

#if defined(__cplusplus)
}
#endif

#endif
