Intentionally public, development-only hosted app keys. Never enroll them for
system, production, W1 or QEMU images. Tarwind trusts their public keys only for
the debug-app scope and the app/executable profile. The private keys are bundled
only with the development signer, never with TarwindKernel.

The app signer requires the input's existing note 7 to be [0,0] (app/executable).
It never rewrites that profile. [1,0] is system/executable and is refused by both
the app signer and TarwindAppTrust.
