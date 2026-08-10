#include "RuntimeAtomic.h"

#include <stdatomic.h>
#include <stdlib.h>

struct HelixRuntimeAtomicFlag {
    atomic_bool value;
};

struct HelixRuntimeAtomicPointer {
    _Atomic(void *) value;
};

HelixRuntimeAtomicFlag *helix_runtime_atomic_flag_create(bool initial_value) {
    HelixRuntimeAtomicFlag *flag = malloc(sizeof(*flag));
    if (flag == NULL) {
        return NULL;
    }
    atomic_init(&flag->value, initial_value);
    return flag;
}

void helix_runtime_atomic_flag_destroy(HelixRuntimeAtomicFlag *flag) {
    free(flag);
}

bool helix_runtime_atomic_flag_load_acquire(const HelixRuntimeAtomicFlag *flag) {
    return atomic_load_explicit(&flag->value, memory_order_acquire);
}

void helix_runtime_atomic_flag_store_release(
    HelixRuntimeAtomicFlag *flag,
    bool value
) {
    atomic_store_explicit(&flag->value, value, memory_order_release);
}

HelixRuntimeAtomicPointer *helix_runtime_atomic_pointer_create(void) {
    HelixRuntimeAtomicPointer *pointer = malloc(sizeof(*pointer));
    if (pointer == NULL) {
        return NULL;
    }
    atomic_init(&pointer->value, NULL);
    return pointer;
}

void helix_runtime_atomic_pointer_destroy(HelixRuntimeAtomicPointer *pointer) {
    free(pointer);
}

void *helix_runtime_atomic_pointer_load_acquire(
    const HelixRuntimeAtomicPointer *pointer
) {
    return atomic_load_explicit(&pointer->value, memory_order_acquire);
}

void helix_runtime_atomic_pointer_store_release(
    HelixRuntimeAtomicPointer *pointer,
    void *value
) {
    atomic_store_explicit(&pointer->value, value, memory_order_release);
}
