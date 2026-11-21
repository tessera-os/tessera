The W1 fixture is extracted unchanged from TarwinW0Verify's InteropW1 corpus.
It is input to the hosted debug signer and a negative hosted-trust test, not a
trusted hosted app. Tests never execute it.

SigningTests adds a synthetic 64-byte finalizer descriptor and two SVC words in
memory for admission tests, with an explicit [0,0] app/executable profile. The
unmodified W1 system/executable image is negative input only. This does not
constitute a compiler-finalized launch fixture; the production signer requires
an existing finalizer note and does not synthesize one.
