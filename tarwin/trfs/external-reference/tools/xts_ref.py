#!/usr/bin/env python3
"""External XTS-AES-256 references and a spec-reading image checker for TRFS v1.

crypt/nist use implementations that share no code with TRFS: pyca/cryptography
(its bundled OpenSSL) and Apple's LibreSSL /usr/bin/openssl. `check` is a second
reading of TRFS.md, not an external reference; it only confirms the decrypted
image layout and SHA-256 rules with Python's hashlib.
"""
import argparse, hashlib, json, subprocess, sys

SECTOR = 4096
LIBRESSL = "/usr/bin/openssl"


def tweak_bytes(index, mode):
    if mode == "le":
        return index.to_bytes(16, "little")
    if mode == "be":
        return index.to_bytes(16, "big")
    if mode == "plus1":
        return (index + 1).to_bytes(16, "little")
    raise SystemExit("bad tweak mode")


def xts(impl, key, tweak, data, decrypt):
    if impl == "pyca":
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        c = Cipher(algorithms.AES(key), modes.XTS(tweak))
        op = c.decryptor() if decrypt else c.encryptor()
        return op.update(data) + op.finalize()
    if impl == "libressl":
        r = subprocess.run(
            [LIBRESSL, "enc", "-aes-256-xts", "-d" if decrypt else "-e", "-nopad",
             "-K", key.hex(), "-iv", tweak.hex()],
            input=data, capture_output=True, check=True)
        return r.stdout
    raise SystemExit("bad impl")


def versions():
    import cryptography
    from cryptography.hazmat.backends.openssl import backend
    libre = subprocess.run([LIBRESSL, "version"], capture_output=True, text=True).stdout.strip()
    return {"pyca_cryptography": cryptography.__version__,
            "pyca_openssl": backend.openssl_version_text(),
            "libressl": libre, "python": sys.version.split()[0]}


def cmd_version(a):
    v = versions()
    if not v["libressl"].startswith("LibreSSL"):
        raise SystemExit("LibreSSL /usr/bin/openssl not found")
    print(json.dumps(v))


def cmd_crypt(a):
    key = bytes.fromhex(a.key)
    assert len(key) == 64
    img = open(a.input, "rb").read()
    assert len(img) % SECTOR == 0
    out = bytearray()
    for i in range(len(img) // SECTOR):
        out += xts(a.impl, key, tweak_bytes(i, a.tweak), img[i * SECTOR:(i + 1) * SECTOR],
                   a.mode == "dec")
    open(a.output, "wb").write(out)


def parse_rsp(path):
    section, cur, cases = None, {}, []
    for line in open(path):
        line = line.strip()
        if line in ("[ENCRYPT]", "[DECRYPT]"):
            section = line[1:-1]
        elif " = " in line:
            k, v = line.split(" = ", 1)
            if k == "COUNT":
                cur = {"section": section}
                cases.append(cur)
            cur[k] = v
    return cases


def cmd_nist(a):
    result = {}
    for impl in ("pyca", "libressl"):
        ok = skipped = 0
        for c in parse_rsp(a.rsp):
            bits = int(c["DataUnitLen"])
            if bits % 8:
                skipped += 1
                continue
            key = bytes.fromhex(c["Key"])
            tw = int(c["DataUnitSeqNumber"]).to_bytes(16, "little")
            pt, ct = bytes.fromhex(c["PT"]), bytes.fromhex(c["CT"])
            if c["section"] == "ENCRYPT":
                good = xts(impl, key, tw, pt, False) == ct
            else:
                good = xts(impl, key, tw, ct, True) == pt
            if not good:
                raise SystemExit(f"{impl} disagrees with NIST {c['section']} COUNT {c['COUNT']}")
            ok += 1
        result[impl] = {"passed": ok, "not_byte_aligned_skipped": skipped}
    print(json.dumps(result))


def u64(b, o):
    return int.from_bytes(b[o:o + 8], "little")


def cmd_check(a):
    img = open(a.image, "rb").read()
    n = len(img) // SECTOR
    sec = lambda i: img[i * SECTOR:(i + 1) * SECTOR]
    anchors = []
    for slot in (0, 1):
        s = sec(slot)
        if s[:8] != bytes.fromhex("5452465300000100"):
            continue
        if hashlib.sha256(s[:4064]).digest() != s[4064:]:
            raise SystemExit(f"anchor {slot}: SHA-256 mismatch")
        if any(s[72:4064]) or u64(s, 24) != n or u64(s, 8) & 1 != slot:
            raise SystemExit(f"anchor {slot}: malformed")
        anchors.append((u64(s, 8), u64(s, 16), s[32:72]))
    if not anchors:
        raise SystemExit("no valid anchor")
    gen, tail, head = max(anchors)
    if head[8:].hex() != a.root:
        raise SystemExit("head digest differs from the writer's root")

    def deref(ref, before):
        idx = u64(ref, 0)
        if not (2 <= idx < before):
            raise SystemExit(f"reference {idx} out of order")
        s = sec(idx)
        if hashlib.sha256(s).digest() != ref[8:]:
            raise SystemExit(f"sector {idx}: SHA-256 mismatch")
        return idx, s

    chain, ref, before = [], head, tail
    while any(ref):
        idx, s = deref(ref, before)
        if s[:8] != bytes.fromhex("5452464e00000100") or any(s[115:128]):
            raise SystemExit(f"record {idx}: bad magic or reserved bytes")
        ln = s[114]
        if any(s[128 + ln:]):
            raise SystemExit(f"record {idx}: name padding")
        chain.append(dict(idx=idx, obj=u64(s, 8), key=u64(s, 16), value=u64(s, 24),
                          blob=s[72:112], tag=s[112], sub=s[113], name=s[128:128 + ln]))
        ref, before = s[32:72], idx

    def newest(pred):
        return next((r for r in chain if pred(r)), None)

    def page(obj, i):
        for r in chain:
            if r["tag"] == 4 and r["obj"] == obj and i >= r["key"]:
                return None
            if r["tag"] == 3 and r["obj"] == obj and r["key"] == i:
                return deref(r["blob"], r["idx"])[1]
        return None

    report = []
    for e in json.load(open(a.expect)):
        node = 1
        for comp in e["path"].split("/"):
            d = newest(lambda r: r["tag"] == 1 and r["obj"] == node and r["name"] == comp.encode())
            if d is None or d["value"] == 0:
                raise SystemExit(f"{e['path']}: missing")
            node = d["value"]
        ino = newest(lambda r: r["tag"] == 2 and r["obj"] == node)
        kind = {1: "file", 2: "directory", 3: "symlink"}[ino["sub"]]
        if kind != e["kind"]:
            raise SystemExit(f"{e['path']}: kind {kind}")
        length = ino["value"]
        if kind == "file":
            data = b"".join(page(node, i) or bytes(SECTOR) for i in range((length + SECTOR - 1) // SECTOR))
            data = data[:length]
        elif kind == "symlink":
            data = deref(ino["blob"], ino["idx"])[1][:length]
        else:
            data = b""
        if "sha256" in e and hashlib.sha256(data).hexdigest() != e["sha256"]:
            raise SystemExit(f"{e['path']}: content differs")
        report.append({"path": e["path"], "kind": kind, "length": length})
    print(json.dumps({"generation": gen, "tail": tail, "records": len(chain), "checked": report}))


p = argparse.ArgumentParser()
sub = p.add_subparsers(required=True)
s = sub.add_parser("version"); s.set_defaults(f=cmd_version)
s = sub.add_parser("crypt"); s.set_defaults(f=cmd_crypt)
s.add_argument("--impl", required=True, choices=["pyca", "libressl"])
s.add_argument("--mode", required=True, choices=["enc", "dec"])
s.add_argument("--tweak", default="le", choices=["le", "be", "plus1"])
s.add_argument("--key", required=True); s.add_argument("--input", required=True)
s.add_argument("--output", required=True)
s = sub.add_parser("nist"); s.set_defaults(f=cmd_nist); s.add_argument("rsp")
s = sub.add_parser("check"); s.set_defaults(f=cmd_check)
s.add_argument("image"); s.add_argument("--root", required=True); s.add_argument("--expect", required=True)
a = p.parse_args(); a.f(a)
