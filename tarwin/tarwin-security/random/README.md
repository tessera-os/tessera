# Tarwin random

`KernelRandom` combines the 64-byte protected TBIB boot seed, a freshly
collected 32-byte checked hardware sample, policy and current epoch with
domain-separated BLAKE3 derive_key. Its ChaCha20 generator uses a fresh key
for each block: the first half replaces the key, only the second supplies
output. Do not copy generator storage, log seeds or expose its state.

The platform serializes all access, calls `reseed` with new checked samples
throughout operation (before the per-sample budget of 32,768 output blocks
is exhausted), and supplies an independently trusted generation
on each request. A restore must update that generation before any guest
CPU resumes. Nil, or a changed generation, disables output until successful
reseed. Never classify a snapshot-capable VM as physical. Debug QEMU
may use swtpm only with a trusted VM-generation witness; certified mode
never credits swtpm or virtio-rng.

Use `word(generation:)` as the input to the W1 placement sampler. This
library does not detect hardware, furnish a generation witness or schedule
the entropy service. Without those platform contracts it does not authorize
live placement.

The native private Random.fill call takes one user address for a 32-byte
seed. It returns the matching 128-bit generation in the two scalar results
(zero only for physical hardware) after fault-checked copy-out. The public
backend fills arbitrary buffers from private per-thread state; its coherent
epoch reader is supplied by the platform. An output buffer may be used only
after success. The provider does not install exception vectors, TLS or a
shared page.
