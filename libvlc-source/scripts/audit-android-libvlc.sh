#!/usr/bin/env bash
# Release gate for Android: fails if a packaged native library is GPL libVLC/FFmpeg, carries code
# from a GPL-only library or a GPL VLC module, or carries a software decoder for a codec whose
# patent pool still licenses — H.264/HEVC, AAC, DTS, VC-1/WMV9, AC-4, TrueHD/MLP (docs/COMPLIANCE.md
# §1.3, §1.4 and §2: the Android build plays those through MediaCodec, via Media3 or libVLC's
# mediacodec module) — or if a package carries VLC's Lua scripts (GPL), libvlcjni's GPL
# RendererDiscoverer class, or a Java/Kotlin source with a GPL header.
#
#   scripts/audit-android-libvlc.sh app-release.apk                 # an APK or an app bundle (.aab)
#   scripts/audit-android-libvlc.sh libvlc-lgpl.aar                 # an AAR
#   scripts/audit-android-libvlc.sh path/to/jni                     # .so files or folders of them
#   scripts/audit-android-libvlc.sh path/to/libvlcjni/libvlc/src    # Java/Kotlin sources
#   scripts/audit-android-libvlc.sh --self-test                     # checks the checks (cc, zip)
#
# The app's release build runs it on every APK and bundle (app/build.gradle.kts,
# AuditLibVlcTask); scripts/build-libvlc-android.sh runs it on the AAR it produces.
#
# Checks, on every lib*.so:
#   * no string reports a GPL licence ("GPL version …", which is what FFmpeg's *_license()
#     returns when configured with --enable-gpl; the LGPL build says "LGPL version 2.1 or later";
#     "nonfree and unredistributable" with --enable-nonfree), no FFmpeg configuration string with
#     --enable-gpl, --enable-nonfree or --enable-postproc, and no VLC module licence string
#     "Licensed under the terms of the GNU General Public License" (the linker usually drops it);
#   * no description string of a GPL VLC module (GPL_MODULE_STRINGS: the ones that declare
#     VLC_LICENSE_GPL_2_PLUS, hqdn3d and i420_rgb_mmx, whose sources carry GPL headers without
#     declaring it, and zvbi, whose libzvbi has GPL-only files) — this is what finds a GPL module
#     in a linked libvlc.so, whose module symbols are not exported; and no deinterlace module
#     with yadif: the module ("Deinterlacing video filter") is allowed only as patched by
#     scripts/vlc-patches-android/0002, which removes yadif (GPL yadif.h/yadif_template.h) and its
#     "Yadif" mode labels, so the module together with a label means yadif's code. The labels
#     alone are not code: an unpatched core lists them among its options even when the module is
#     not linked (the AARs built before lane 26 blacklisted the module and are LGPL-clean);
#   * no defined dynamic symbol of libdvdcss, libdvdnav, libdvdread, libpostproc, x264, x265, liba52,
#     libmpeg2, faad2, Xvid, libdca (matched at the start of the name: FFmpeg's own LGPL code is
#     named ff_*/avpriv_*);
#   * no FFmpeg h264/hevc decoder (ff_h264_decoder, ff_hevc_decoder), nor AC-4/TrueHD/MLP, AAC
#     (aac, aac_fixed, aac_latm), DTS (dca) or VC-1/WMV9 (vc1, vc1image, wmv3, wmv3image, mss2);
#     a library with FFmpeg in it must export its ff_*_decoder symbols, or the check could not see
#     them and fails;
#   * no software encoder of those pools either (ff_aac/dca/truehd/mlp_encoder): the patent
#     licences cover encoders too, and Umbra never encodes through libVLC;
#   * libVLC (libvlc_new) carries the mediacodec module's "mediacodec-audio" option: with no
#     software AAC decoder, that module (turned on by LibVlcGuard.OPTIONS) is how libVLC plays AAC;
#   * no libvlcjni built for RendererDiscoverer (the class name it looks up in JNI_OnLoad, or its
#     Java_org_videolan_libvlc_RendererDiscoverer_* natives): scripts/libvlcjni-patches/0001;
#   * the symbol table and the strings could be read (a tool error fails the audit).
# And on every APK, bundle and AAR: no assets/lua/ entry (VLC's Lua scripts are GPL); no
# org/videolan/libvlc/RendererDiscoverer class (libvlcjni's only GPL-headed source, GPL 2+,
# docs/COMPLIANCE.md §1.4), looked for among the archive's classes, in every jar inside it (an
# AAR's classes.jar) and in every dex file (APK, bundle); and no Java/Kotlin source inside it whose
# header (its first 40 lines) says "GNU General Public License". Folders are searched for the
# same: libraries, packages, jars, class files and Java/Kotlin sources. A class file carries no
# licence header, so for compiled code the RendererDiscoverer check is the one that applies;
# scripts/build-libvlc-android.sh runs the source check on libvlcjni's sources before it builds.
# Uses the NDK's llvm-nm and llvm-strings ($ANDROID_HOME/ndk/*), else llvm-nm/nm and strings
# on PATH.
set -euo pipefail

[[ $# -gt 0 ]] || { echo "usage: $0 file.apk|file.aab|file.aar|lib.so|dir ... | --self-test" >&2; exit 2; }

# --self-test: builds small libraries (cc) and archives (zip) that each break one rule, plus a
# clean one, and checks the audit fails each of them and passes the clean one.
if [[ "$1" == --self-test ]]; then
  for t in cc zip; do command -v "$t" >/dev/null || { echo "self-test needs $t" >&2; exit 2; }; done
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  so() { # name C-source
    mkdir -p "$t/$1"; printf '%s\n' "$2" > "$t/$1/x.c"
    cc -shared -fPIC -o "$t/$1/lib$1.so" "$t/$1/x.c" || { echo "self-test: cc failed" >&2; exit 2; }
  }
  so clean 'const char *libvlc_new(void){return "libavcodec license: LGPL version 2.1 or later";} int ff_ac3_decoder; int ff_mpeg4_decoder; int ff_wmv2_decoder; const char *umbra_deinterlace = "Deinterlacing video filter"; const char *umbra_mc = "mediacodec-audio";'
  so h264 'int ff_h264_decoder; const char *libvlc_new(void){return "x";}'
  # One library per removed decoder (no royalties, docs/COMPLIANCE.md §2), each otherwise clean.
  for d in aac aac_fixed aac_latm dca vc1 vc1image wmv3 wmv3image mss2; do
    so "$d" "int ff_${d}_decoder; int ff_ac3_decoder; const char *f(void){return \"libavcodec license: LGPL version 2.1 or later\";}"
  done
  so nomediacodec 'const char *libvlc_new(void){return "libavcodec license: LGPL version 2.1 or later";} int ff_ac3_decoder;'
  so dvdcss 'int dvdcss_open(void){return 0;}'
  so gplffmpeg 'const char *f(void){return "libavcodec license: GPL version 2 or later";} int ff_ac3_decoder;'
  so hidden 'const char *f(void){return "libavcodec license: LGPL version 2.1 or later";}'
  so gplmodule 'const char *libvlc_new(void){return "High Quality 3D Denoiser filter";} const char *umbra_mc = "mediacodec-audio";'
  so yadif 'const char *libvlc_new(void){return "Yadif (2x)";} const char *umbra_deinterlace = "Deinterlacing video filter"; const char *umbra_mc = "mediacodec-audio";'
  # An unpatched core's option labels, without the deinterlace module: not GPL code, must pass.
  so corelabels 'const char *libvlc_new(void){return "Yadif";} const char *umbra_label = "Yadif (2x)"; const char *umbra_mc = "mediacodec-audio";'
  for e in aac dca truehd mlp; do
    so "${e}enc" "int ff_${e}_encoder; int ff_ac3_decoder; const char *f(void){return \"libavcodec license: LGPL version 2.1 or later\";}"
  done
  # libvlcjni as built before scripts/libvlcjni-patches/0001: it looks the GPL class up.
  so rendererjni 'const char *umbra_cls = "org/videolan/libvlc/RendererDiscoverer"; int Java_org_videolan_libvlc_MediaPlayer_nativeSetRenderer(void){return 0;}'
  so cleanjni 'int Java_org_videolan_libvlc_MediaPlayer_nativeSetRenderer(void){return 0;} const char *umbra_cls = "org/videolan/libvlc/RendererItem";'
  gpl_header='/*
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */'
  lgpl_header='/*
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 */'
  # Sources: one GPL-headed file fails its folder (Java or Kotlin); LGPL and headerless pass.
  mkdir -p "$t/gplsrc/org/videolan/libvlc" "$t/gplkt" "$t/lgplsrc/org/videolan/libvlc"
  printf '%s\npackage org.videolan.libvlc;\nclass Gpl {}\n' "$gpl_header" > "$t/gplsrc/org/videolan/libvlc/Gpl.java"
  printf '%s\npackage org.videolan.libvlc;\nclass Ok {}\n' "$lgpl_header" > "$t/gplsrc/org/videolan/libvlc/Ok.java"
  printf '%s\npackage a\nclass A\n' "$gpl_header" > "$t/gplkt/A.kt"
  printf '%s\npackage org.videolan.libvlc\nclass Ok\n' "$lgpl_header" > "$t/lgplsrc/org/videolan/libvlc/Ok.kt"
  printf 'package org.videolan.libvlc;\nclass RendererItem {}\n' > "$t/lgplsrc/org/videolan/libvlc/RendererItem.java"
  # AARs: a classes.jar with the GPL class (or only a nested class of it) fails; RendererItem passes.
  for c in renderer renderernested cleanaar; do mkdir -p "$t/$c/jar/org/videolan/libvlc"; done
  echo x > "$t/renderer/jar/org/videolan/libvlc/RendererDiscoverer.class"
  echo x > "$t/renderernested/jar/org/videolan/libvlc/RendererDiscoverer\$Description.class"
  echo x > "$t/cleanaar/jar/org/videolan/libvlc/RendererItem.class"
  echo x > "$t/cleanaar/jar/org/videolan/libvlc/MediaPlayer.class"
  for c in renderer renderernested cleanaar; do
    (cd "$t/$c/jar" && zip -q -r ../classes.jar org) && (cd "$t/$c" && zip -q "$c.aar" classes.jar)
  done
  # An APK whose dex still defines the class; an AAR that ships a GPL-headed source.
  mkdir -p "$t/rendererapk" && printf 'dex\n035 Lorg/videolan/libvlc/RendererDiscoverer; ' > "$t/rendererapk/classes.dex"
  (cd "$t/rendererapk" && zip -q rendererapk.apk classes.dex)
  mkdir -p "$t/gplsrcaar/src" && cp "$t/gplsrc/org/videolan/libvlc/Gpl.java" "$t/gplsrcaar/src/Gpl.java"
  (cd "$t/gplsrcaar" && zip -q -r gplsrcaar.aar src)
  mkdir -p "$t/notelf" && echo 'not a library' > "$t/notelf/libnotelf.so"
  mkdir -p "$t/lua/assets/lua/playlist" && echo '--' > "$t/lua/assets/lua/playlist/youtube.lua"
  (cd "$t/lua" && zip -q -r lua.aar assets)
  self="${BASH_SOURCE[0]}" fails=0
  bash "$self" "$t/clean/libclean.so" >/dev/null || { echo "self-test: the clean library failed"; fails=1; }
  bash "$self" "$t/corelabels/libcorelabels.so" >/dev/null || { echo "self-test: the core's yadif labels alone failed"; fails=1; }
  for c in cleanjni/libcleanjni.so lgplsrc cleanaar/cleanaar.aar; do
    bash "$self" "$t/$c" >/dev/null || { echo "self-test: $c failed"; bash "$self" "$t/$c" || true; fails=1; }
  done
  for c in h264/libh264.so dvdcss/libdvdcss.so gplffmpeg/libgplffmpeg.so hidden/libhidden.so \
           gplmodule/libgplmodule.so yadif/libyadif.so notelf/libnotelf.so lua/lua.aar \
           aac/libaac.so aac_fixed/libaac_fixed.so aac_latm/libaac_latm.so dca/libdca.so vc1/libvc1.so \
           vc1image/libvc1image.so wmv3/libwmv3.so wmv3image/libwmv3image.so mss2/libmss2.so \
           nomediacodec/libnomediacodec.so aacenc/libaacenc.so dcaenc/libdcaenc.so truehdenc/libtruehdenc.so \
           mlpenc/libmlpenc.so rendererjni/librendererjni.so gplsrc gplkt renderer/renderer.aar \
           renderernested/renderernested.aar rendererapk/rendererapk.apk gplsrcaar/gplsrcaar.aar; do
    if bash "$self" "$t/$c" >/dev/null 2>&1; then echo "self-test: $c passed the audit"; fails=1; fi
  done
  [[ $fails -eq 0 ]] && echo "libVLC audit self-test passed"
  exit $fails
fi

find_tool() { # name fallback...
  local name="$1"; shift
  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [[ -n "$sdk" && -d "$sdk/ndk" ]] || continue
    local t
    t="$(ls -1d "$sdk"/ndk/*/toolchains/llvm/prebuilt/*/bin/"$name" 2>/dev/null | sort -V | tail -1 || true)"
    [[ -n "$t" && -x "$t" ]] && { echo "$t"; return; }
  done
  local c
  for c in "$name" "$@"; do command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return; }; done
  echo "error: $name not found (set ANDROID_HOME to an SDK with an NDK)" >&2; exit 2
}
NM="$(find_tool llvm-nm nm)"
STRINGS="$(find_tool llvm-strings strings)"

GPL_SYMBOLS='^(dvdcss_|dvdnav_|dvdread_|DVDOpen|DVDClose|pp_postprocess|pp_get_|postproc_|x264_|x265_|a52_|mpeg2_|NeAACDec|faacDec|xvid_|dca_)'
PATENT_SYMBOLS='^ff_(h264|hevc|ac4|truehd|mlp|aac|aac_fixed|aac_latm|libfdk_aac|dca|vc1|vc1image|wmv3|wmv3image|mss2)_decoder$|^ff_(h264|hevc|vc1|wmv3)_(cuvid|qsv|crystalhd|mmal|v4l2m2m)_decoder$|^ff_(aac|libfdk_aac|dca|truehd|mlp)_encoder$'
# libvlcjni's renderer discovery (the GPL class, see the top): the class name JNI_OnLoad looks
# up, and the natives of libvlcjni-rendererdiscoverer.c.
RENDERER_JNI_STRINGS='org/videolan/libvlc/RendererDiscoverer|Java_org_videolan_libvlc_RendererDiscoverer_'
RENDERER_CLASS='org/videolan/libvlc/RendererDiscoverer'
# libVLC's MediaCodec audio decoder option (modules/codec/omxil/mediacodec.c), see the top.
MEDIACODEC_AUDIO_STRING='mediacodec-audio'
# The last one is the licence a GPL VLC module declares (VLC_LICENSE_GPL_2_PLUS in vlc_plugin.h;
# LGPL modules say "GNU Lesser General Public License").
GPL_STRINGS='(^|[^L])GPL version|nonfree and unredistributable|--enable-gpl|--enable-nonfree|--enable-postproc|Licensed under the terms of the GNU General Public License'
# set_description() of VLC 3.0's GPL modules (whole strings), so that a linked one shows even
# though its licence string and symbols are gone. hqdn3d and i420_rgb_mmx carry GPL code without
# declaring it: hqdn3d.h (MPlayer) and i420_rgb_mmx.h; the plain C and SSE2 i420_rgb modules are
# LGPL. "VBI and Teletext decoder" is zvbi (libzvbi 0.2.35 compiles GPL-only pdc.c, packet-830.c
# and exp-vtx.c).
GPL_MODULE_STRINGS='^(Lua interpreter|Lua HTTP|Real RTSP|Real demuxer|Rotate video filter|Stereo to mono downmixer|Simple decoder for Dolby Surround encoded streams|Headphone virtual spatialization effect|RTP stream output|RTSP VoD server|Legacy RTSP VoD server|Cyclic stream output|File logger|File logging|System logger \(syslog\)|Dummy interface|MusePack demuxer|T\.140 text encoder|M3U playlist export|Stats encoder function|Stats decoder function|Remote control interface|Hotkeys management interface|Network synchronization|motion control interface|Mouse gestures control interface|Infrared remote control interface|Submission of played songs to last\.fm|Podcasts|Network streams \(SAP\)|Zeroconf services|H\.264/MPEG-4 Part 10/AVC encoder.*|H\.262/MPEG-2 encoder \(x262\)|H\.265/HEVC encoder \(x265\)|High Quality 3D Denoiser filter|i420_rgb_mmx|VBI and Teletext decoder)$'
# The deinterlace module ("Deinterlacing video filter") is LGPL once
# scripts/vlc-patches-android/0002 is applied; unpatched, it carries yadif.h/yadif_template.h
# (FFmpeg's old GPL yadif) and the "Yadif"/"Yadif (2x)" mode labels. Both together fail. An
# unpatched core also lists the labels (src/libvlc-module.c), which alone are not yadif's code.
DEINTERLACE_MODULE_STRING='^Deinterlacing video filter$'
YADIF_LABELS='^(Yadif|Yadif \(2x\))$'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
libs=()
n=0
java_checked=0
# A Java/Kotlin source whose header says GPL. LGPL headers say "GNU Lesser General Public
# License" (LGPL 2.0: "GNU Library General Public License"), which this does not match.
gpl_header() { # file
  awk 'NR > 40 {exit} tolower($0) ~ /gnu general public license/ {found = 1; exit} END {exit !found}' "$1"
}
check_source() { # file shown-name
  java_checked=$((java_checked + 1))
  if gpl_header "$1"; then echo "FAIL (Java/Kotlin source with a GPL header): $2"; status=1; fi
}
# The GPL class among a jar's or an archive's entries (a nested class alone counts too).
check_class_entries() { # entries shown-name
  local hits
  hits="$(grep -E "(^|/)${RENDERER_CLASS}(\\\$[^/]*)?\.class\$" <<<"$1" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL (libvlcjni's GPL RendererDiscoverer class): $2"; head -5 <<<"$hits" | sed 's/^/    /'; status=1
  fi
}
# Classes, dex files, nested jars and sources of a zip (APK, bundle, AAR, jar).
check_java_archive() { # archive entries shown-name
  local f="$1" entries="$2" shown="$3" e d inner
  check_class_entries "$entries" "$shown"
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    n=$((n + 1)); d="$work/$n"; mkdir -p "$d"
    # unzip -p rather than extracting by name: the names are wildcard patterns to unzip, and
    # escaping keeps "[" literal ("$" in class names is literal anyway).
    unzip -p "$f" "$(sed 's/[][*?\\]/\\&/g' <<<"$e")" > "$d/entry" 2>/dev/null \
      || { echo "error: cannot read $e in $shown" >&2; exit 2; }
    case "$e" in
      *.jar)
        inner="$(unzip -Z1 "$d/entry" 2>/dev/null)" || { echo "error: cannot read $e in $shown" >&2; exit 2; }
        check_java_archive "$d/entry" "$inner" "$shown!$e" ;;
      *.dex)
        java_checked=$((java_checked + 1))
        if LC_ALL=C grep -qaF "L$RENDERER_CLASS" "$d/entry"; then
          echo "FAIL (libvlcjni's GPL RendererDiscoverer class): $shown!$e"; status=1
        fi ;;
      *) check_source "$d/entry" "$shown!$e" ;;
    esac
  done < <(grep -E '\.(jar|dex|java|kt)$' <<<"$entries" || true)
}
# Extracts the native libraries of an APK, bundle or AAR, and fails on Lua scripts in it.
unpack() { # archive
  local f="$1" entries
  entries="$(unzip -Z1 "$f" 2>/dev/null)" || { echo "error: cannot read $f" >&2; exit 2; }
  if grep -qE '(^|/)assets/lua/' <<<"$entries"; then
    echo "FAIL (VLC Lua scripts, GPL): $f"; grep -E '(^|/)assets/lua/' <<<"$entries" | head -5 | sed 's/^/    /'; status=1
  fi
  check_java_archive "$f" "$entries" "$f"
  n=$((n + 1)); mkdir -p "$work/$n"
  # unzip exits 11 when one of the patterns matches nothing.
  unzip -q -o "$f" 'lib/*.so' 'base/lib/*.so' 'jni/*.so' -d "$work/$n" 2>/dev/null || [[ $? -eq 11 ]] \
    || { echo "error: cannot read $f" >&2; exit 2; }
}
for input in "$@"; do
  if [[ -d "$input" ]]; then
    while IFS= read -r -d '' f; do libs+=("$f"); done < <(find "$input" -type f -name 'lib*.so' -print0)
    while IFS= read -r -d '' f; do unpack "$f"; done \
      < <(find "$input" -type f \( -name '*.apk' -o -name '*.aab' -o -name '*.aar' \) -print0)
    while IFS= read -r -d '' f; do
      entries="$(unzip -Z1 "$f" 2>/dev/null)" || { echo "error: cannot read $f" >&2; exit 2; }
      check_java_archive "$f" "$entries" "$f"
    done < <(find "$input" -type f -name '*.jar' -print0)
    while IFS= read -r -d '' f; do check_source "$f" "$f"; done \
      < <(find "$input" -type f \( -name '*.java' -o -name '*.kt' \) -print0)
    check_class_entries "$(cd "$input" && find . -type f -name '*.class' | sed 's|^\./||')" "$input"
  elif [[ "$input" == *.so ]]; then
    libs+=("$input")
  elif [[ -f "$input" ]]; then
    unpack "$input"
  else
    echo "error: $input not found" >&2; exit 2
  fi
done
while IFS= read -r -d '' f; do libs+=("$f"); done < <(find "$work" -type f -name '*.so' -print0)

if [[ ${#libs[@]} -eq 0 ]]; then
  if [[ $status -eq 0 && $java_checked -gt 0 ]]; then
    echo "libVLC audit passed: no native libraries, $java_checked Java/Kotlin sources or dex files ($*)"
  elif [[ $status -eq 0 ]]; then
    echo "libVLC audit: no native libraries in $* (nothing to check)"
  fi
  exit $status
fi

vlc=0
for lib in "${libs[@]}"; do
  shown="${lib#"$work"/*/}"
  # A tool that cannot read the library must not pass it.
  syms="$("$NM" -D --defined-only "$lib" 2>/dev/null)" || { echo "FAIL (cannot read the symbols): $shown"; status=1; continue; }
  syms="$(awk '{print $NF}' <<<"$syms")"
  strs="$("$STRINGS" "$lib")" || { echo "FAIL (cannot read the strings): $shown"; status=1; continue; }
  if grep -q '^libvlc_new$' <<<"$syms"; then vlc=$((vlc + 1)); fi
  hits="$(grep -E "$GPL_SYMBOLS" <<<"$syms" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL (GPL library code): $shown"; head -10 <<<"$hits" | sed 's/^/    /'; status=1
  fi
  hits="$(grep -E "$PATENT_SYMBOLS" <<<"$syms" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL (software decoder for a patent-pool codec): $shown"; sed 's/^/    /' <<<"$hits"; status=1
  fi
  if grep -q '^libavcodec license: ' <<<"$strs" && ! grep -qE '^ff_[a-z0-9_]+_decoder$' <<<"$syms"; then
    echo "FAIL (FFmpeg inside, but its decoders are not exported: cannot check them): $shown"; status=1
  fi
  hits="$(grep -oE -- ".{0,30}($GPL_STRINGS).{0,30}" <<<"$strs" | sort -u || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL (GPL licence or configuration string): $shown"; head -10 <<<"$hits" | sed 's/^/    /'; status=1
  fi
  # Only where VLC is (libvlccore's API, or a plugin's entry point): the strings are generic.
  hits=""
  if grep -qE '^(libvlc_new|vlc_entry.*)$' <<<"$syms"; then hits="$(grep -E -- "$GPL_MODULE_STRINGS" <<<"$strs" | sort -u || true)"; fi
  if [[ -n "$hits" ]]; then
    echo "FAIL (GPL VLC module): $shown"; head -10 <<<"$hits" | sed 's/^/    /'; status=1
  fi
  hits="$(grep -oE -- "$RENDERER_JNI_STRINGS" <<<"$strs" | sort -u || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL (libvlcjni built for the GPL RendererDiscoverer class; scripts/libvlcjni-patches/0001 not applied): $shown"
    sed 's/^/    /' <<<"$hits"; status=1
  fi
  if grep -q '^libvlc_new$' <<<"$syms" && ! grep -qF -- "$MEDIACODEC_AUDIO_STRING" <<<"$strs"; then
    echo "FAIL (libVLC without the MediaCodec audio decoder: AAC would not play): $shown"; status=1
  fi
  if grep -qE '^(libvlc_new|vlc_entry.*)$' <<<"$syms" && grep -qE -- "$DEINTERLACE_MODULE_STRING" <<<"$strs" \
     && grep -qE -- "$YADIF_LABELS" <<<"$strs"; then
    echo "FAIL (deinterlace module with GPL yadif: scripts/vlc-patches-android/0002 not applied): $shown"
    grep -E -- "$YADIF_LABELS" <<<"$strs" | sort -u | sed 's/^/    /'; status=1
  fi
done

if [[ $status -eq 0 ]]; then
  echo "libVLC audit passed: ${#libs[@]} native libraries, $vlc with libVLC, $java_checked Java/Kotlin sources or dex files ($*)"
fi
exit $status
