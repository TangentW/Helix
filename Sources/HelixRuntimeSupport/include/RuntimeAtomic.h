#ifndef HELIX_RUNTIME_ATOMIC_H
#define HELIX_RUNTIME_ATOMIC_H

#include <stdbool.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef struct HelixRuntimeAtomicFlag HelixRuntimeAtomicFlag;
typedef struct HelixRuntimeAtomicPointer HelixRuntimeAtomicPointer;

HelixRuntimeAtomicFlag *helix_runtime_atomic_flag_create(bool initial_value);
void helix_runtime_atomic_flag_destroy(HelixRuntimeAtomicFlag *flag);
bool helix_runtime_atomic_flag_load_acquire(const HelixRuntimeAtomicFlag *flag);
void helix_runtime_atomic_flag_store_release(
    HelixRuntimeAtomicFlag *flag,
    bool value
);

HelixRuntimeAtomicPointer *helix_runtime_atomic_pointer_create(void);
void helix_runtime_atomic_pointer_destroy(HelixRuntimeAtomicPointer *pointer);
void *helix_runtime_atomic_pointer_load_acquire(
    const HelixRuntimeAtomicPointer *pointer
);
void helix_runtime_atomic_pointer_store_release(
    HelixRuntimeAtomicPointer *pointer,
    void *value
);

#if defined(__cplusplus)
}
#endif

#endif
