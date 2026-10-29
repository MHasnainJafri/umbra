#!/usr/bin/env bash
# Release gate: fails if an app bundle (or a VLCKit/MobileVLCKit xcframework) links GPL-only
# code or software decoders for patent-pool codecs (H.264/HEVC must decode through VideoToolbox
# only), or links libvlc statically into an app or extension executable.
#
#   scripts/audit-gpl-symbols.sh path/to/Umbra.app              # Mac app
#   scripts/audit-gpl-symbols.sh path/to/UmbraMobile.app        # iPhone/iPad app (device or Simulator)
#   scripts/audit-gpl-symbols.sh Vendor/VLCKit/MobileVLCKit.xcframework
#   scripts/audit-gpl-symbols.sh --self-test                     # checks the checks (clang)
#
# Works on both bundle layouts: macOS (Contents/MacOS, Contents/Frameworks, Contents/PlugIns)
# and iOS (flat: the executable at the top, Frameworks/, PlugIns/*.appex).
#
# The binary that carries libvlc (VLCKit.framework / MobileVLCKit.framework) is also checked for
# GPL VLC modules and GPL contrib code, which export no symbols of their own once linked:
#   * no VLC module licence string "Licensed under the terms of the GNU General Public License"
#     (only modules that declare VLC_LICENSE_GPL_2_PLUS contain it), and no FFmpeg licence or
#     configuration string of a GPL or nonfree build;
#   * no description string of a GPL VLC module (GPL_VLC_MODULE_STRINGS: the ones that declare
#     VLC_LICENSE_GPL_2_PLUS, hqdn3d and i420_rgb_mmx, whose sources are GPL without declaring
#     it, and zvbi, whose libzvbi brings GPL-only files: pdc.c, packet-830.c, exp-vtx.c);
#   * no "Yadif" mode label: Umbra's libVLC is built with scripts/vlc-patches/0002, which takes
#     yadif (yadif.h, yadif_template.h: GPL) out of the deinterlace module, and its labels out of
#     the module and the core; a label means an unpatched module;
#   * when the binary still has its local symbols (VLCKit's do): no yadif, hqdn3d or libzvbi code.
# scripts/build-vlckit.sh also checks every source file compiled into the libVLC it links
# (scripts/audit-libvlc-sources.py), which this check cannot see.
set -euo pipefail

# --self-test: builds small dynamic frameworks (clang) that each break one rule, plus a clean one,
# and checks the audit fails each of them and passes the clean one.
if [[ "${1:-}" == --self-test ]]; then
  command -v xcrun >/dev/null || { echo "self-test needs Xcode (xcrun clang)" >&2; exit 2; }
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  fw() { # name C-source
    mkdir -p "$t/$1/Fake.framework"; printf '%s\n' "$2" > "$t/$1/x.c"
    xcrun clang -dynamiclib -O0 -o "$t/$1/Fake.framework/Fake" "$t/$1/x.c" \
      || { echo "self-test: clang failed" >&2; exit 2; }
  }
  base='const char *libvlc_new(void){return "Licensed under the terms of the GNU Lesser General Public License, version 2.1 or later.";} const char *const umbra_lgpl[] = {"Deinterlacing video filter", "Linear", "libavcodec license: LGPL version 2.1 or later"};'
  fw clean "$base"
  fw gpllicence "$base const char *const s1[] = {\"Licensed under the terms of the GNU General Public License, version 2 or later.\"};"
  fw gplffmpeg "$base const char *const s1[] = {\"libavcodec license: GPL version 2 or later\"};"
  fw hqdn3d "$base const char *const s1[] = {\"High Quality 3D Denoiser filter\"};"
  fw rotate "$base const char *const s1[] = {\"Rotate video filter\"};"
  fw teletext "$base const char *const s1[] = {\"VBI and Teletext decoder\"};"
  fw yadiflabel "$base const char *const s1[] = {\"Yadif (2x)\"};"
  fw yadifcode "$base void yadif_filter_line_c(void){}"
  fw zvbicode "$base int vbi_decode_vps_pdc(void){return 0;}"
  fw h264 "$base int ff_h264_decoder;"
  self="${BASH_SOURCE[0]}" fails=0
  bash "$self" "$t/clean" >/dev/null || { echo "self-test: the clean framework failed"; bash "$self" "$t/clean" || true; fails=1; }
  for c in gpllicence gplffmpeg hqdn3d rotate teletext yadiflabel yadifcode zvbicode h264; do
    if bash "$self" "$t/$c" >/dev/null 2>&1; then echo "self-test: $c passed the audit"; fails=1; fi
  done
  [[ $fails -eq 0 ]] && echo "GPL/patent audit self-test passed"
  exit $fails
fi

APP="${1:?usage: $0 path/to/App.app | path/to/Framework.xcframework | --self-test}"
[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 2; }

# GPL-only libraries that must never be present (copyright: LGPL compliance). Matched at the
# start of a symbol name (nm prints "addr T _name"), so FFmpeg's own LGPL decoders with similar
# names (ff_dca_*, avpriv_dca_* for DTS, ff_mpeg2_*) are not mistaken for libdca or libmpeg2.
GPL_PATTERNS='(^|[[:space:]])_?(x264_|x265_|a52_|dvdcss_|faad|mpeg2_|xvid_|dca_|libpostproc|postproc_|vidstab|rubberband|frei0r)'
# Software decoders for encumbered video codecs (patents: route via VideoToolbox).
PATENT_PATTERNS='(^|_)ff_(h264|hevc)_decoder$|(^|_)ff_(h264|hevc)_(cuvid|qsv)_decoder$|(^|_)ff_(ac4|truehd|mlp)_decoder$'
# libvlc / VLCKit code: allowed only inside a dynamic framework, never in an executable.
LIBVLC_DEFINED='[[:space:]][TtSsDd][[:space:]](_libvlc_new|_OBJC_CLASS_\$_VLCMediaPlayer)$'
# In the libvlc binary, whole strings as `strings` prints them: the licence of a GPL VLC module,
# and the licence or configuration line of a GPL or nonfree FFmpeg.
GPL_VLC_LICENCE_STRINGS='^(Licensed under the terms of the GNU General Public License.*|lib(avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample|postproc) license: (GPL|nonfree).*|.*--enable-(gpl|nonfree|postproc)( .*)?|.*nonfree and unredistributable.*)$'
# set_description() of VLC 3.0's GPL modules (the list of scripts/audit-android-libvlc.sh): the
# ones that declare VLC_LICENSE_GPL_2_PLUS; hqdn3d and i420_rgb_mmx (GPL sources, no
# declaration); zvbi ("VBI and Teletext decoder": libzvbi 0.2.35 carries GPL-only pdc.c,
# packet-830.c and exp-vtx.c); and the yadif mode labels, which only an unpatched deinterlace
# module or core contains (scripts/vlc-patches/0002). The patched deinterlace module is LGPL.
GPL_VLC_MODULE_STRINGS='^(Lua interpreter|Lua HTTP|Real RTSP|Real demuxer|Rotate video filter|Stereo to mono downmixer|Simple decoder for Dolby Surround encoded streams|Headphone virtual spatialization effect|RTP stream output|RTSP VoD server|Legacy RTSP VoD server|Cyclic stream output|File logger|File logging|System logger \(syslog\)|Dummy interface|MusePack demuxer|T\.140 text encoder|M3U playlist export|Stats encoder function|Stats decoder function|Remote control interface|Hotkeys management interface|Network synchronization|motion control interface|Mouse gestures control interface|Infrared remote control interface|Submission of played songs to last\.fm|Podcasts|Network streams \(SAP\)|Zeroconf services|H\.264/MPEG-4 Part 10/AVC encoder.*|H\.262/MPEG-2 encoder \(x262\)|H\.265/HEVC encoder \(x265\)|High Quality 3D Denoiser filter|i420_rgb_mmx|VBI and Teletext decoder|Yadif|Yadif \(2x\))$'
# The same code by symbol, where the binary keeps its local symbols: yadif (algo_yadif.c,
# yadif.h), hqdn3d, libzvbi (vbi_*, also exported).
GPL_VLC_SYMBOLS='[[:space:]]_?(yadif_[A-Za-z0-9_]*|RenderYadif[A-Za-z0-9_]*|[Hh][Qq][Dd][Nn]3[Dd][A-Za-z0-9_]*|_?vbi_[A-Za-z0-9_]+)$'

status=0
checked=0
libvlc_bins=0
while IFS= read -r -d '' bin; do
  # Debug symbols repeat the symbol table of the binary they describe; that binary is checked.
  [[ "$bin" == *.dSYM/* ]] && continue
  kind="$(file -b "$bin")"
  case "$bin" in
    *.framework/*)
      # A static framework would be linked into the executable that uses it, which makes the
      # app a work based on libvlc under the LGPL: only dynamic frameworks may carry it.
      if [[ "$kind" == *"ar archive"* ]] && { nm -g "$bin" 2>/dev/null || true; } | grep -Eq "$LIBVLC_DEFINED"; then
        echo "FAIL (LGPL): static framework with libvlc: $bin"; status=1; continue
      fi ;;
  esac
  [[ "$kind" == *Mach-O* ]] || continue
  checked=$((checked + 1))
  syms="$(nm -gU "$bin" 2>/dev/null || true; nm -u "$bin" 2>/dev/null || true)"
  if grep -Eq "$GPL_PATTERNS" <<<"$syms"; then
    echo "FAIL (GPL): $bin"; grep -E "$GPL_PATTERNS" <<<"$syms" | head -20; status=1
  fi
  if grep -Eq "$PATENT_PATTERNS" <<<"$syms"; then
    echo "FAIL (software decoder for patent-pool codec): $bin"; grep -E "$PATENT_PATTERNS" <<<"$syms" | head -20; status=1
  fi
  # The binary that carries libvlc: GPL VLC modules and GPL contrib code (see the top).
  if grep -Eq "$LIBVLC_DEFINED" <<<"$syms"; then
    libvlc_bins=$((libvlc_bins + 1))
    # A tool that cannot read the binary must not pass it.
    strs="$(strings -a "$bin")" || { echo "FAIL (cannot read the strings): $bin"; status=1; continue; }
    allsyms="$(nm "$bin")" || { echo "FAIL (cannot read the symbols): $bin"; status=1; continue; }
    hits="$(grep -E -- "$GPL_VLC_LICENCE_STRINGS" <<<"$strs" | cut -c1-160 | sort -u || true)"
    if [[ -n "$hits" ]]; then
      echo "FAIL (GPL licence or configuration string in libvlc): $bin"; head -10 <<<"$hits" | sed 's/^/    /'; status=1
    fi
    hits="$(grep -E -- "$GPL_VLC_MODULE_STRINGS" <<<"$strs" | sort -u || true)"
    if [[ -n "$hits" ]]; then
      echo "FAIL (GPL VLC module, or a deinterlace module with yadif, in libvlc): $bin"; head -20 <<<"$hits" | sed 's/^/    /'; status=1
    fi
    hits="$(grep -E -- "$GPL_VLC_SYMBOLS" <<<"$allsyms" | head -20 || true)"
    if [[ -n "$hits" ]]; then
      echo "FAIL (yadif, hqdn3d or libzvbi code in libvlc): $bin"; sed 's/^/    /' <<<"$hits"; status=1
    fi
  fi
  # Static archives of LGPL code would make the app a derivative work: VLCKit must be dynamic.
  # Executables are everything outside a framework that is not a dylib: Contents/MacOS/* on the
  # Mac, the top-level binary on iOS, and app extensions (widgets) on both. Debug builds move an
  # executable's code into <name>.debug.dylib next to it, so that counts as the executable too.
  # (No `;&` fall-through: macOS runs this with bash 3.2.)
  executable=yes
  case "$bin" in
    *.framework/*) executable=no ;;
    *.debug.dylib|*__preview.dylib) ;;
    *.dylib) executable=no ;;
  esac
  if [[ $executable == yes ]] && { nm -gU "$bin" 2>/dev/null || true; } | grep -Eq "$LIBVLC_DEFINED"; then
    echo "FAIL (LGPL): libvlc/VLCKit is statically linked into $bin"; status=1
  fi
  # A framework that does carry libvlc must be a dynamic library.
  if [[ "$bin" == *.framework/* && "$kind" != *"dynamically linked shared library"* ]] \
     && { nm -gU "$bin" 2>/dev/null || true; } | grep -Eq "$LIBVLC_DEFINED"; then
    echo "FAIL (LGPL): $bin carries libvlc but is not a dynamic library ($kind)"; status=1
  fi
done < <(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' -o -path '*.framework/*' \) -print0)

if [[ $checked -eq 0 ]]; then echo "error: no Mach-O binaries found in $APP" >&2; exit 2; fi
if [[ $status -eq 0 ]]; then echo "GPL/patent symbol audit passed for $APP ($checked binaries, $libvlc_bins with libvlc)"; fi
exit $status
