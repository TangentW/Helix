#ifndef HELIX_DEV_RUNTIME_PROBE_H
#define HELIX_DEV_RUNTIME_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Stable C rendezvous symbol observed by the generated LLDB handoff.
__attribute__((visibility("default"), swift_name("helixDevRuntimeHandoffProbe()")))
void helix_dev_runtime_handoff_probe(void);

#ifdef __cplusplus
}
#endif

#endif
