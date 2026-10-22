#!/usr/bin/env python3
"""Rewrite APK zip: native libs stored uncompressed (fix for extractNativeLibs=false).
Preserves every entry's data bytes exactly; only compress_type for *.so changes."""
import sys, zipfile, shutil, os

src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src, "r")
if os.path.exists(dst):
    os.remove(dst)
zout = zipfile.ZipFile(dst, "w")

changed = []
STALE = (".SF", ".RSA", ".DSA", ".EC", "MANIFEST.MF")
for info in zin.infolist():
    name = info.filename
    if name.startswith("META-INF/") and name.endswith(STALE):
        changed.append("STRIPPED:" + name)
        continue
    data = zin.read(name)
    ni = zipfile.ZipInfo(name, date_time=info.date_time)
    ni.external_attr = info.external_attr
    ni.internal_attr = info.internal_attr
    ni.create_system = info.create_system
    method = info.compress_type
    if name.endswith(".so") and method == zipfile.ZIP_DEFLATED:
        method = zipfile.ZIP_STORED
        changed.append(name)
    ni.compress_type = method
    # preserve extra field minus stale zip64 (zipfile re-adds as needed)
    zout.writestr(ni, data)

zout.close()
zin.close()
print(f"fixed {len(changed)} .so entries -> STORED: {changed}")
print(f"size: {os.path.getsize(src)} -> {os.path.getsize(dst)}")
