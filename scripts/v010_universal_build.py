#!/usr/bin/env python3
"""v0.1.0 multi-ABI finalize pipeline (disk-constrained).

From ONE gradle v7a-only unsigned APK plus the published, byte-verified
v0.1.0 arm64 APK, produce TWO signed APKs:

  A. nexora-v0.1.0-v7a.apk        — armeabi-v7a only (older 32-bit devices)
  B. nexora-v0.1.0-universal.apk  — armeabi-v7a + arm64-v8a (works everywhere)

Steps:
  1. stream the gradle APK entry-by-entry (no full extraction)
  2. strip v7a native libs (EXCEPT libapp.so — Dart AOT snapshot) via
     arm-linux-gnueabihf-objcopy --strip-unneeded  (same recipe as v0.1.0)
  3. re-zip: .so STORED (extractNativeLibs=false contract), rest DEFLATED
  4. universal adds lib/arm64-v8a/*.so lifted byte-identical from the
     published arm64 release (already stripped + STORED there)
  5. zipalign -f -p 4 -> apksigner sign (release JKS, v1+v2+v3) -> verify
  6. aapt badging sanity + SHA-256 for both outputs

Usage: KS_PASS=... python3 v010_universal_build.py
"""
import os, subprocess, sys, zipfile, tempfile, shutil

ROOT   = "/home/z/my-project/drs-nexora"
BT     = "/home/z/toolchain/android-sdk/build-tools/34.0.0"
KS     = f"{ROOT}/android/app/nexora-release.jks"
ALIAS  = "nexora"
IN_APK = f"{ROOT}/build/app/outputs/flutter-apk/app-release.apk"
REF_A64= "/home/z/my-project/download/nexora-v0.1.0-arm64.apk"
OUT_V7A= "/home/z/my-project/download/nexora-v0.1.0-v7a.apk"
OUT_UNI= "/home/z/my-project/download/nexora-v0.1.0-universal.apk"

OBJCOPY    = "/tmp/ba64v7/usr/bin/arm-linux-gnueabihf-objcopy"
OC_ENV     = {**os.environ, "LD_LIBRARY_PATH": "/tmp/ba64v7/usr/lib/x86_64-linux-gnu"}
STALE      = (".SF", ".RSA", ".DSA", ".EC", "MANIFEST.MF")
STRIPTMP   = tempfile.mkdtemp(prefix="v7astrip")

KS_PASS = os.environ.get("KS_PASS", "")
if not KS_PASS:
    sys.exit("KS_PASS env required")

# Production keystore identity (nexora-release.jks, alias nexora).
# Compare with: apksigner verify --print-certs <apk>
EXPECTED_CERT_SHA256 = "ae74add09a58f8063ab45e18c1b99e9e1352acf2f46af67789d74f097e44fa6b"


def strip_so(src_bytes: bytes, arcname: str) -> bytes:
    """objcopy --strip-unneeded on a native lib; falls back to raw bytes."""
    tmp_in = os.path.join(STRIPTMP, "in.so")
    tmp_out = os.path.join(STRIPTMP, "out.so")
    with open(tmp_in, "wb") as f:
        f.write(src_bytes)
    r = subprocess.run([OBJCOPY, "--strip-unneeded", tmp_in, tmp_out],
                       env=OC_ENV, capture_output=True)
    if r.returncode != 0:
        print(f"  !! objcopy failed for {arcname} ({r.stderr.decode()[:120]}) — packaging as-is")
        return src_bytes
    with open(tmp_out, "rb") as f:
        out = f.read()
    print(f"  stripped {arcname}: {len(src_bytes):,} -> {len(out):,} bytes")
    return out


def aapt_checks(path: str):
    env = {**os.environ, "LC_ALL": "C"}
    r = subprocess.run([f"{BT}/aapt", "dump", "badging", path],
                       env=env, capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith(("package:", "native-code", "sdkVersion",
                            "application-label:")):
            print("   ", line.strip())


def finalize(unsigned_path: str, final_path: str, label: str):
    aligned = unsigned_path + ".aligned"
    subprocess.run([f"{BT}/zipalign", "-f", "-p", "4",
                    unsigned_path, aligned], check=True)
    os.replace(aligned, final_path)
    subprocess.run([f"{BT}/apksigner", "sign",
                    "--ks", KS, "--ks-key-alias", ALIAS,
                    "--ks-pass", f"pass:{KS_PASS}",
                    "--key-pass", f"pass:{KS_PASS}",
                    "--min-sdk-version", "24", final_path], check=True)
    v = subprocess.run([f"{BT}/apksigner", "verify", "--print-certs", final_path],
                       capture_output=True, text=True)
    cert = [l for l in v.stdout.splitlines() if "SHA-256" in l]
    print(f"[{label}] signed; size {os.path.getsize(final_path):,} bytes")
    for l in cert:
        print("   ", l.strip())
    # HARD GUARD: the shipped certificate MUST be the production identity.
    # A wrong/rotated key installs on clean devices but bricks every
    # existing install with INSTALL_FAILED_UPDATE_INCOMPATIBLE — so a
    # mismatch here is a release-blocking failure, never a warning.
    digest_line = next((l for l in v.stdout.splitlines()
                        if "certificate SHA-256 digest" in l), "")
    digest = digest_line.rsplit(":", 1)[-1].strip().lower()
    if digest != EXPECTED_CERT_SHA256:
        sys.exit(f"SIGNING GUARD FAILED [{label}]: {digest or 'no-cert'} "
                 f"!= {EXPECTED_CERT_SHA256} — DO NOT RELEASE this APK")
    print(f"    signing guard OK [{label}]: production identity confirmed")
    aapt_checks(final_path)


def main():
    tmp_v7a = OUT_V7A + ".unsigned"
    tmp_uni = OUT_UNI + ".unsigned"
    for p in (tmp_v7a, tmp_uni, OUT_V7A, OUT_UNI):
        if os.path.exists(p):
            os.remove(p)

    with zipfile.ZipFile(IN_APK) as zin, \
         zipfile.ZipFile(tmp_v7a, "w", zipfile.ZIP_DEFLATED) as z7, \
         zipfile.ZipFile(tmp_uni, "w", zipfile.ZIP_DEFLATED) as zu:
        # NOTE: gradle (without abiFilters) packages plugin JNI libs for ALL
        # ABIs the AARs ship (arm64-v8a + x86_64 partial sets). A partial
        # lib/<abi>/ dir on-device means the loader extracts THAT abi and
        # crashes on the missing libflutter.so — so both outputs must carry
        # EXACTLY ONE complete ABI set each. We keep only armeabi-v7a from
        # the gradle stream; the universal's arm64 set comes solely from the
        # published, byte-verified arm64 release (complete + pre-stripped).
        for info in zin.infolist():
            name = info.filename
            if name.startswith("META-INF/") and name.endswith(STALE):
                continue  # stale signatures (unsigned build shouldn't have any)
            if name.startswith("lib/") and not name.startswith("lib/armeabi-v7a/"):
                continue  # drop partial foreign-ABI sets (arm64/x86_64)
            data = zin.read(name)
            is_v7a_so = (name.startswith("lib/armeabi-v7a/")
                         and name.endswith(".so")
                         and not name.endswith("libapp.so"))
            if is_v7a_so:
                data = strip_so(data, name)
            method = zipfile.ZIP_STORED if name.endswith(".so") else zipfile.ZIP_DEFLATED
            zi = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            zi.compress_type = method
            zi.external_attr = info.external_attr or (0o644 << 16)
            z7.writestr(zi, data)
            zu.writestr(zi, data)

        # inject the COMPLETE arm64 lib set, byte-identical from the published verified release
        injected = 0
        with zipfile.ZipFile(REF_A64) as zref:
            for rinfo in zref.infolist():
                if rinfo.filename.startswith("lib/arm64-v8a/"):
                    rdata = zref.read(rinfo.filename)
                    ri = zipfile.ZipInfo(rinfo.filename, (2026, 1, 1, 0, 0, 0))
                    ri.compress_type = zipfile.ZIP_STORED
                    ri.external_attr = 0o644 << 16
                    zu.writestr(ri, rdata)
                    injected += 1
                    print(f"  injected {rinfo.filename}: {len(rdata):,} bytes (byte-identical to published v0.1.0)")
        assert injected == 4, f"expected 4 arm64 libs, got {injected}"

    print("== finalize v7a ==")
    finalize(tmp_v7a, OUT_V7A, "v7a")
    print("== finalize universal ==")
    finalize(tmp_uni, OUT_UNI, "universal")

    os.remove(tmp_v7a)
    os.remove(tmp_uni)
    shutil.rmtree(STRIPTMP, ignore_errors=True)

    for p in (OUT_V7A, OUT_UNI):
        h = subprocess.run(["sha256sum", p], capture_output=True, text=True)
        print(h.stdout.strip())


if __name__ == "__main__":
    main()
