#include "HelixDevRuntimeProbe.h"

// Keep a distinct externally visible address for LLDB. The Swift caller lives
// in another compilation module, so optimization cannot bypass this C entry.
__attribute__((noinline, used, visibility("default")))
void helix_dev_runtime_handoff_probe(void) {}
