#ifndef HELIX_RUNTIME_C_H
#define HELIX_RUNTIME_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { HelixRuntimeCMessageCapacity = 1024 };

typedef enum HelixRuntimeCStatus {
    HelixRuntimeCStatusSuccess = 0,
    HelixRuntimeCStatusInvalidInput = 1,
    HelixRuntimeCStatusUnsupportedSignature = 2,
    HelixRuntimeCStatusInvocationFailure = 3,
} HelixRuntimeCStatus;

typedef struct HelixRuntimeCArgument {
    const char *encoding;
    const void *bytes;
    size_t byte_count;
} HelixRuntimeCArgument;

typedef struct HelixRuntimeCResult {
    HelixRuntimeCStatus status;
    size_t result_byte_count;
    char message[HelixRuntimeCMessageCapacity];
} HelixRuntimeCResult;

/// Returns whether the fixed AOT trampoline matrix can execute this exact C
/// ABI shape. It performs no symbol lookup and allocates no executable memory.
bool helix_runtime_c_signature_is_supported(
    const char *const *argument_encodings,
    size_t argument_count,
    const char *result_encoding
);

/// Calls one compiler-bound C function pointer after revalidating every
/// argument encoding and byte width. The pointer is supplied by the trusted
/// App registry; downloaded code never chooses an address or symbol string.
bool helix_runtime_c_invoke(
    const void *function,
    const HelixRuntimeCArgument *arguments,
    size_t argument_count,
    const char *result_encoding,
    void *result_bytes,
    size_t result_capacity,
    HelixRuntimeCResult *result
);

#ifdef __cplusplus
}
#endif

#endif
