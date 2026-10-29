#!/usr/bin/env bash
# Release gate for Android: fails if a packaged native library is GPL libVLC/FFmpeg, carries code
# from a GPL-only library or a GPL VLC module, or carries an H.264/HEVC software decoder
# (docs/COMPLIANCE.md §1.3, §1.4 and §2: the Android build plays those through MediaCodec via
# Media3), or if a package carries VLC's Lua scripts (GPL).
#
#   scripts/audit-android-libvlc.sh app-release.apk                 # an APK or an app bundle (.aab)
#   scripts/audit-android-libvlc.sh libvlc-lgpl.aar                 # an AAR
#   scripts/audit-android-libvlc.sh path/to/jni                     # .so files or folders of them
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
#   * no FFmpeg h264/hevc decoder (ff_h264_decoder, ff_hevc_decoder), nor AC-4/TrueHD/MLP; a
#     library with FFmpeg in it must export its ff_*_decoder symbols, or the check could not see
#     them and fails;
#   * the symbol table and the strings could be read (a tool error fails the audit).
# And on every APK, bundle and AAR: no assets/lua/ entry (VLC's Lua scripts are GPL).
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
  so clean 'const char *libvlc_new(void){return "libavcodec license: LGPL version 2.1 or later";} int ff_aac_decoder; const char *umbra_deinterlace = "Deinterlacing video filter";'
  so h264 'int ff_h264_decoder; const char *libvlc_new(void){return "x";}'
  so dvdcss 'int dvdcss_open(void){return 0;}'
  so gplffmpeg 'const char *f(void){return "libavcodec license: GPL version 2 or later";} int ff_aac_decoder;'
  so hidden 'const char *f(void){return "libavcodec license: LGPL version 2.1 or later";}'
  so gplmodule 'const char *libvlc_new(void){return "High Quality 3D Denoiser filter";}'
  so yadif 'const char *libvlc_new(void){return "Yadif (2x)";} const char *umbra_deinterlace = "Deinterlacing video filter";'
  # An unpatched core's option labels, without the deinterlace module: not GPL code, must pass.
  so corelabels 'const char *libvlc_new(void){return "Yadif";} const char *umbra_label = "Yadif (2x)";'
  mkdir -p "$t/notelf" && echo 'not a library' > "$t/notelf/libnotelf.so"
  mkdir -p "$t/lua/assets/lua/playlist" && echo '--' > "$t/lua/assets/lua/playlist/youtube.lua"
  (cd "$t/lua" && zip -q -r lua.aar assets)
  self="${BASH_SOURCE[0]}" fails=0
  bash "$self" "$t/clean/libclean.so" >/dev/null || { echo "self-test: the clean library failed"; fails=1; }
  bash "$self" "$t/corelabels/libcorelabels.so" >/dev/null || { echo "self-test: the core's yadif labels alone failed"; fails=1; }
  for c in h264/libh264.so dvdcss/libdvdcss.so gplffmpeg/libgplffmpeg.so hidden/libhidden.so \
           gplmodule/libgplmodule.so yadif/libyadif.so notelf/libnotelf.so lua/lua.aar; do
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
PATENT_SYMBOLS='^ff_(h264|hevc|ac4|truehd|mlp)_decoder$'
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
# Extracts the native libraries of an APK, bundle or AAR, and fails on Lua scripts in it.
unpack() { # archive
  local f="$1" entries
  entries="$(unzip -Z1 "$f" 2>/dev/null)" || { echo "error: cannot read $f" >&2; exit 2; }
  if grep -qE '(^|/)assets/lua/' <<<"$entries"; then
    echo "FAIL (VLC Lua scripts, GPL): $f"; grep -E '(^|/)assets/lua/' <<<"$entries" | head -5 | sed 's/^/    /'; status=1
  fi
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
  [[ $status -eq 0 ]] && echo "libVLC audit: no native libraries in $* (nothing to check)"
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
  if grep -qE '^(libvlc_new|vlc_entry.*)$' <<<"$syms" && grep -qE -- "$DEINTERLACE_MODULE_STRING" <<<"$strs" \
     && grep -qE -- "$YADIF_LABELS" <<<"$strs"; then
    echo "FAIL (deinterlace module with GPL yadif: scripts/vlc-patches-android/0002 not applied): $shown"
    grep -E -- "$YADIF_LABELS" <<<"$strs" | sort -u | sed 's/^/    /'; status=1
  fi
done

if [[ $status -eq 0 ]]; then
  echo "libVLC audit passed: ${#libs[@]} native libraries, $vlc with libVLC ($*)"
fi
exit $status
