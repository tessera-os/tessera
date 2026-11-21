# Stage-0 QEMU verification

Experimental, verification-only Swift for disposable emulator kernels. This
is not an audited production crypto library. No keys are generated and no
private key material is compiled into this module.

Edwards arithmetic follows [public-domain TweetNaCl](https://tweetnacl.cr.yp.to/)
and RFC 8032. The verifier rejects noncanonical points/scalars, negative zero,
the identity key and keys outside the prime-order subgroup. SHA-512 uses
FIPS 180-4. The public-data scalar multiplication is variable-time.

ML-DSA-65 follows FIPS 204 with SHAKE from FIPS 202. The eight polynomials
(8 KiB) live in caller-provided scratch. The small test fixture is public
verification data only (key, context, message, signature) from
[NIST ACVP-Server, ML-DSA sigVer FIPS204, group 3 case 43](https://github.com/usnistgov/ACVP-Server/tree/master/gen-val/json-files/ML-DSA-sigVer-FIPS204).

Run `swift test -c release` here. Passing these host vectors does not
authenticate an archive or constitute a guest boot.
