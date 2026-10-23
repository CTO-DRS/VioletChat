#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_v018.py — تحقق ثنائي مستقل لAPK الخاص بإصدار v0.1.8.
الفحوص:
  1) ZIP سليم ويتضمن AndroidManifest.xml + resources.arsc
  2) اسم الحزمة com.drs.violetchat (manifest، UTF-16LE)
  3) versionName 0.1.7 (manifest، UTF-16LE)
  4) versionCode = 14 (سيم(schema) AXML: قراءة الخاصية مباشرة)
  5) مورد default_web_client_id موجود (resources.arsc — عميل OAuth ويب)
  6) شهادة توقيع APK Signing Block v2 = شهادة الإنتاج (SHA-1 924d6c62…376b)
الاستخدام: python3 verify_v017.py <path.apk>
"""
import hashlib
import struct
import sys
import zipfile

PROD_SHA1 = "924d6c62097ec89e997da06940fac961adeb376b"
EXPECTED_PKG = "com.drs.violetchat"
EXPECTED_VNAME = "0.1.8"
EXPECTED_VCODE = 15

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"[{'✓' if ok else '✗'}] {name}" + (f" — {detail}" if detail else ""))


# ---------------------------------------------------------------
# 1) ZIP structure
# ---------------------------------------------------------------
apk_path = sys.argv[1]
zf = zipfile.ZipFile(apk_path)
names = zf.namelist()
check("ZIP سليم", True, f"{len(names)} ملفاً داخل الحزمة")
check("AndroidManifest.xml موجود", "AndroidManifest.xml" in names)
check("resources.arsc موجود", "resources.arsc" in names)

manifest = zf.read("AndroidManifest.xml")
arsc = zf.read("resources.arsc")

# ---------------------------------------------------------------
# 2,3) package name + versionName (UTF-16LE in AXML string pool)
# ---------------------------------------------------------------
m16 = manifest.decode("utf-16-le", errors="ignore")
check(f"اسم الحزمة = {EXPECTED_PKG}", EXPECTED_PKG in m16)
check(f"versionName = {EXPECTED_VNAME}", EXPECTED_VNAME in m16)

# ---------------------------------------------------------------
# 4) versionCode via minimal AXML attribute walk
# ---------------------------------------------------------------
def axml_first_element_attrs(data):
    """يرجع قائمة (ns, name, raw, typed_data) لأول عنصر XML (manifest)."""
    # AXML header: u16 type(0x0003), u16 headerSize, u32 size ثم string pool…
    # نبحث عن أول chunk بنوع 0x0102 (START_ELEMENT).
    pos = 8  # بعد رأس الملف
    while pos + 8 <= len(data):
        ctype, hsize, csize = struct.unpack_from("<HHI", data, pos)
        if ctype == 0x0102:  # XML_START_ELEMENT
            base = pos
            # رأس العنصر 16 بايت ثم ns(4) name(4) attrStart(2)… — وattrStart
            # نسبي للرأس الممتد (بعد 16 بايت) لا لبداية الchunk.
            attr_start, attr_size, attr_count = struct.unpack_from(
                "<HHH", data, base + 24)
            attrs = []
            for i in range(attr_count):
                off = base + 16 + attr_start + i * attr_size
                ans, anm, araw = struct.unpack_from("<III", data, off)
                # typed value: size(2) res0(1) dataType(1) data(4)
                dsize, res0, dtype = struct.unpack_from("<HBB", data, off + 12)
                dval = struct.unpack_from("<I", data, off + 16)[0]
                attrs.append((ans, anm, araw, dtype, dval))
            return attrs
        pos += csize if csize > 0 else 8
    return []


# أسماء الخصائص تُفهرَس من string pool — نقرأه لتفسير name index
def axml_strings(data):
    # أول chunk بعد الرأس هو StringPool (0x0001)
    ctype, hsize, csize = struct.unpack_from("<HHI", data, 8)
    if ctype != 0x0001:
        return []
    str_count, style_count, flags, str_start, _ = struct.unpack_from(
        "<IIIII", data, 16)
    offsets = struct.unpack_from(f"<{str_count}I", data, 36)
    utf8 = bool(flags & 0x100)
    out = []
    for o in offsets:
        p = 8 + str_start + o  # offsets نسبية لبداية chunk
        if utf8:
            # u8 len(s), u8 len(bytes) (قد تكون 2 بايت إذا High bit) — مبسط:
            if data[p] & 0x80:
                p += 2
            else:
                p += 1
            if data[p] & 0x80:
                p += 2
            else:
                p += 1
            end = data.index(b"\x00", p)
            out.append(data[p:end].decode("utf-8", errors="replace"))
        else:
            slen = struct.unpack_from("<H", data, p)[0]
            if slen & 0x8000:  # طويل
                slen = ((slen & 0x7FFF) << 16) | struct.unpack_from(
                    "<H", data, p + 2)[0]
                p += 4
            else:
                p += 2
            out.append(data[p:p + (slen * 2)].decode("utf-16-le"))
    return out


strings = axml_strings(manifest)
attrs = axml_first_element_attrs(manifest)
vcode = None
pkg_from_attr = None
for ns, nm, raw, dtype, dval in attrs:
    nm_s = strings[nm] if nm < len(strings) else f"?{nm}"
    if nm_s == "versionCode" and dtype == 0x10:  # INT_DEC
        vcode = dval
    if nm_s == "package" and raw != 0xFFFFFFFF:
        # raw هو فهرس string pool
        if raw < len(strings):
            pkg_from_attr = strings[raw]
check(f"versionCode = {EXPECTED_VCODE}", vcode == EXPECTED_VCODE,
      f"مقروء من AXML: {vcode}")
if pkg_from_attr:
    check(f"سمة package = {EXPECTED_PKG}", pkg_from_attr == EXPECTED_PKG,
          pkg_from_attr)

# ---------------------------------------------------------------
# 5) default_web_client_id في resources.arsc (UTF-16LE أو UTF-8)
# ---------------------------------------------------------------
key = "default_web_client_id"
found = key.encode("utf-16-le") in arsc or key.encode("utf-8") in arsc
check("مورد default_web_client_id موجود (عميل OAuth ويب)", found)

# ---------------------------------------------------------------
# 6) APK Signing Block v2 → شهادة الإنتاج
# ---------------------------------------------------------------
def signing_block_cert_sha1s(path):
    """يعرض SHA-1 لكل شهادات مخطط التوقيع v2 (0x7109871a)."""
    import os
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        # EOCD: آخر 22…66000 بايت — نبحث عن التوقيع
        f.seek(max(0, size - 66000))
        tail = f.read()
        eocd_off = tail.rfind(b"PK\x05\x06")
        if eocd_off < 0:
            return None, "لا EOCD"
        cd_size, cd_off = struct.unpack_from("<II", tail, eocd_off + 12)
        # البلوك السحري يقع مباشرة قبل جدول المركزية: magic عند cd_off-16.
        magic_off = cd_off - 16
        with open(path, "rb") as f2:
            f2.seek(magic_off)
            magic = f2.read(16)
        if magic != b"APK Sig Block 42":
            return None, "لا APK Signing Block (حزمة غير موقعة v2؟)"
        # تخطيط البلوك: [u64 size][pairs][u64 size][magic] حيث
        # size = len(pairs) + 24، والبلوك ينتهي بالضبط عند بداية CD.
        with open(path, "rb") as f2:
            f2.seek(cd_off - 24)
            sz_end = struct.unpack_from("<Q", f2.read(8))[0]
            pairs_start = cd_off - sz_end
            f2.seek(pairs_start)
            payload = f2.read(sz_end - 24)  # منطقة الأزواج فقط
        sha1s = []
        pos = 0
        while pos + 12 <= len(payload):
            plen, pid = struct.unpack_from("<QI", payload, pos)
            if pid == 0x7109871a:
                val = payload[pos + 12: pos + 8 + plen]
                # signers: u32 len ثم سلسلة
                signers_len = struct.unpack_from("<I", val, 0)[0]
                signers = val[4: 4 + signers_len]
                sp = 0
                while sp + 4 <= len(signers):
                    signer_len = struct.unpack_from("<I", signers, sp)[0]
                    signer = signers[sp + 4: sp + 4 + signer_len]
                    sp += 4 + signer_len
                    # داخل signer: u32 signed_data_len ثم signed_data ثم
                    # signatures/public key (لا نحتاجها)
                    sd_len = struct.unpack_from("<I", signer, 0)[0]
                    sd = signer[4: 4 + sd_len]
                    # signed_data: u32 digests_len … ثم u32 certs_len ثم سلسلة
                    dg_len = struct.unpack_from("<I", sd, 0)[0]
                    p2 = 4 + dg_len
                    certs_len = struct.unpack_from("<I", sd, p2)[0]
                    certs = sd[p2 + 4: p2 + 4 + certs_len]
                    cp = 0
                    while cp + 4 <= len(certs):
                        cert_len = struct.unpack_from("<I", certs, cp)[0]
                        der = certs[cp + 4: cp + 4 + cert_len]
                        cp += 4 + cert_len
                        sha1s.append(hashlib.sha1(der).hexdigest())
                break
            pos += 8 + plen
        return sha1s, None


sha1s, err = signing_block_cert_sha1s(apk_path)
if err:
    check("شهادة التوقيع", False, err)
else:
    ok = PROD_SHA1 in sha1s
    check("شهادة الإنتاج (SHA-1)", ok,
          f"الشهادات في الحزمة: {', '.join(sha1s) if sha1s else 'لا شيء'}")

# ---------------------------------------------------------------
print("\n===== الملخص =====")
failed = [r for r in results if not r[1]]
print(f"الفحوص: {len(results) - len(failed)}/{len(results)} ناجحة")
if failed:
    for n, _, d in failed:
        print(f"  فاشل: {n} {d}")
    sys.exit(1)
print("النتيجة: الحزمة تحقق هوية v0.1.8 كاملة ✓")
