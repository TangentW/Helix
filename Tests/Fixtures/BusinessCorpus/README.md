# Helix business corpus

These checked-in sources are intentionally application-shaped rather than
single-instruction compiler probes. The test harness compiles each file with the
installed Swift frontend, lowers it to HLBC, verifies the encoded image, and
executes multiple normal, boundary, and failure-path inputs in HLVM without
recompiling the fixture for each invocation.

The harness requests Helix's semantic-lowering SIL profile. This is the same
toolchain-pinned fallback used by production patch compilation when optimized
SIL exposes private Swift standard-library storage. Optimized SIL remains the
source of release implementation fingerprints; the VM never models those
private layouts.

The corpus covers checkout arithmetic and bounds, form validation, feed scoring,
and an order-state decision. Patch-local nominal declarations intentionally live
at file scope; function-local nominal types remain an exact compiler rejection.
It is a deterministic repository regression corpus; it is not the external
top-200 application corpus required for product qualification.
