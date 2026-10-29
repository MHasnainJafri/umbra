#!/usr/bin/env bash
# Builds the universal engine: an LGPL-only, Apple-Silicon VLCKit.xcframework with
#   * no GPL contribs (VLCKit's contrib bootstrap always passes --disable-gpl, which drops
#     a52/liba52, x264, x265, libdvdcss, postproc, faad, libmpeg2 ...)
#   * libavcodec H.264 and HEVC software decoders removed (decode via VideoToolbox only)
#   * AC-4 / TrueHD / MLP decoders removed; AC-3 and E-AC-3 kept (see docs/COMPLIANCE.md)
#
# Output: Vendor/VLCKit/VLCKit.xcframework, then:
#   cd App && UMBRA_WITH_VLCKIT=YES xcodegen generate
#
# With --ios it builds the same configuration as MobileVLCKit.xcframework for the iPhone/iPad
# app instead (device arm64 + Apple-Silicon simulator arm64, a dynamic framework the app embeds):
#   scripts/build-vlckit.sh --ios
#   cd App && UMBRA_IOS_WITH_VLCKIT=YES xcodegen generate --spec mobile.yml
# Both builds share one checkout under Vendor/VLCKit/build; libvlc and its contribs are built
# per platform, so building one never invalidates the other.
#
# Requires macOS with Xcode 16+. libvlc builds its own autotools/cmake/meson under
# extras/tools, so Homebrew versions do not matter. A clean build takes 45–90 minutes on an
# M-series Mac; re-running resumes where it stopped.
#
# Licence (docs/COMPLIANCE.md §1.3, §1.4): the framework links no GPL code. Beyond the contrib
# bootstrap's --disable-gpl/--disable-gnuv3:
#   * the VLC modules that declare VLC_LICENSE_GPL_2_PLUS are removed before linking
#     (GPL_MODULES below; on VLCKit 3.6.0 that removes dolby_surround_decoder, dummy, mono,
#     rotate, stream_out_cycle, stream_out_rtp, syslog and vod_rtsp, which upstream links), and
#     zvbi, whose libzvbi 0.2.35 compiles GPL-only files (pdc.c, packet-830.c, exp-vtx.c) into
#     the library (teletext subtitles are then decoded by the LGPL telx module);
#   * hqdn3d (GPL sources) stays out (upstream's own blacklist, and GPL_MODULES);
#   * the deinterlace module is kept, without yadif (scripts/vlc-patches/0002: yadif.h and
#     yadif_template.h are GPL), so interlaced video is still deinterlaced (mode "x", as before);
#   * every source file compiled into the linked libVLC is checked for a GPL header
#     (scripts/audit-libvlc-sources.py) and the framework binary for GPL modules and code
#     (scripts/audit-gpl-symbols.sh); the result is written next to the framework
#     (VLCKit.licence-audit.txt / MobileVLCKit.licence-audit.txt), which scripts/build-mac.sh
#     requires before it builds an app that embeds the framework.
# libVLC sources are changed only by the patches in scripts/vlc-patches (LGPL, published with the
# script); everything else is build configuration. The LGPL obligation is satisfied by linking
# dynamically and pointing users to the upstream source of the tag below plus those patches
# (Settings › About).
set -euo pipefail

TARGET_OS=macos
case "${1:-}" in
  "") ;;
  --ios) TARGET_OS=ios ;;
  *) echo "usage: $0 [--ios]" >&2; exit 2 ;;
esac

VLCKIT_REF="${VLCKIT_REF:-3.6.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/Vendor/VLCKit/build}"
OUT="${OUT:-$ROOT/Vendor/VLCKit}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "error: VLCKit must be built on macOS" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d VLCKit ]]; then
  git clone --depth 1 --branch "$VLCKIT_REF" https://code.videolan.org/videolan/VLCKit.git
fi
cd VLCKit
KIT="$PWD"

# 1. libvlc at the hash this VLCKit release was tested with, plus VLCKit's own patches. This
#    mirrors the network step of buildMobileVLCKit.sh so the configuration below can be applied
#    before anything is compiled; the build itself then runs with -n (no network steps).
TESTED_HASH="$(sed -n 's/^TESTEDHASH="\([0-9a-f]*\)".*/\1/p' buildMobileVLCKit.sh)"
[[ -n "$TESTED_HASH" ]] || { echo "error: could not read TESTEDHASH from buildMobileVLCKit.sh" >&2; exit 1; }
if [[ ! -d libvlc/vlc ]]; then
  git clone https://code.videolan.org/videolan/vlc.git --branch 3.0.x --single-branch libvlc/vlc
  (cd libvlc/vlc && git checkout -B localBranch "$TESTED_HASH" \
    && git -c user.name=umbra-build -c user.email=build@localhost am "$KIT"/libvlc/patches/*.patch)
fi

# 1b. Umbra's own libvlc patches (scripts/vlc-patches, LGPL: published with the source):
#     0001 keeps the system HTTP proxy away from loopback stream grants;
#     0002 builds the deinterlace module without yadif (GPL).
#     The patches are applied to the working tree, never committed. When they are not all
#     applied as they are now (a fresh tree, or one patched by an earlier version of a patch),
#     the files they touch are restored from HEAD (libvlc + VLCKit's patches) and all reapplied.
UMBRA_PATCHES=()
for patch in "$ROOT"/scripts/vlc-patches/*.patch; do
  if [[ -f "$patch" ]]; then UMBRA_PATCHES+=("$patch"); fi
done
if (( ${#UMBRA_PATCHES[@]} > 0 )); then
  umbra_patches_current=1
  for patch in "${UMBRA_PATCHES[@]}"; do
    (cd libvlc/vlc && git apply --reverse --check "$patch" >/dev/null 2>&1) || umbra_patches_current=0
  done
  if (( umbra_patches_current == 0 )); then
    for patch in "${UMBRA_PATCHES[@]}"; do
      (cd libvlc/vlc && git apply --numstat "$patch" | cut -f3 | while IFS= read -r file; do
        git checkout -q HEAD -- "$file" || exit 1; done) \
        || { echo "error: could not restore the files $(basename "$patch") touches" >&2; exit 1; }
    done
    for patch in "${UMBRA_PATCHES[@]}"; do
      (cd libvlc/vlc && git apply "$patch") || { echo "error: could not apply $(basename "$patch")" >&2; exit 1; }
    done
    # A patch that changes a Makefile.am needs fresh Makefile.in files: an earlier build's would
    # still list what the patch removed. buildMobileVLCKit.sh bootstraps libvlc when configure
    # is missing.
    rm -f libvlc/vlc/configure
  fi
fi
# 1c. yadif's GPL files are deleted too (0002 already stops building them), so that no later
#     change to the build can compile them back in.
DEINTERLACE="libvlc/vlc/modules/video_filter/deinterlace"
rm -f "$DEINTERLACE/algo_yadif.c" "$DEINTERLACE/algo_yadif.h" "$DEINTERLACE/yadif.h" "$DEINTERLACE/yadif_template.h"
! grep -q yadif libvlc/vlc/modules/video_filter/Makefile.am && [[ -f "$DEINTERLACE/algo_x.c" ]] \
  || { echo "error: the deinterlace module still lists yadif (scripts/vlc-patches/0002 not applied?)" >&2; exit 1; }

# 2. FFmpeg configuration: no GPL, no nonfree, no software decoders for patent-pool codecs.
#    Make expands FFMPEGCONF when the recipe runs, so appending to the rules is enough.
RULES="libvlc/vlc/contrib/src/ffmpeg/rules.mak"
if ! grep -q "Umbra LGPL/patent policy" "$RULES"; then
  printf '\n# Umbra LGPL/patent policy\nFFMPEGCONF += --disable-gpl --disable-nonfree --disable-decoder=h264 --disable-decoder=hevc --disable-decoder=ac4 --disable-decoder=truehd --disable-decoder=mlp\n' >> "$RULES"
fi

# macOS 27 ships a BSD /sbin/sha512sum that cannot check sums piped on stdin, which libvlc's
# tool build does for every download. Its tools bin directory comes first on the build PATH,
# so a shim there routes checksums through shasum instead.
TOOLS_BIN="libvlc/vlc/extras/tools/build/bin"
probe="$(mktemp)"
if ! (cd "$(dirname "$probe")" && shasum -a 512 "$(basename "$probe")" | sha512sum -c >/dev/null 2>&1); then
  mkdir -p "$TOOLS_BIN"
  printf '#!/bin/sh\nexec /usr/bin/shasum -a 512 "$@"\n' > "$TOOLS_BIN/sha512sum"
  chmod +x "$TOOLS_BIN/sha512sum"
fi
rm -f "$probe"

# 3. Build. "-a aarch64" restricts libvlc to Apple Silicon, but buildMobileVLCKit.sh also turns
#    on its simulator pass for -a, which on macOS would build libvlc a second time. A copy of the
#    script switches that pass off for macOS (build configuration only).
#
#    The same copy adds compiler flags for current Xcode, whose clang rejects some of the older
#    C in libvlc's contribs:
#      -Dfdopen=fdopen  zlib's zutil.h replaces fdopen() with NULL whenever TargetConditionals
#                       defines TARGET_OS_MAC (it does on every Apple SDK now); defining the name
#                       as itself makes zlib skip that override.
#      -I compat        libpng's pngpriv.h includes classic Mac OS <fp.h> under the same
#                       TARGET_OS_MAC test; compat/fp.h just includes <math.h>.
#      -Wno-error=...   K&R-era code that newer clang turned from warnings into errors.
#    and archives VLCKit.framework for macOS 14 (the app's minimum); the project's own 10.9 target
#    is below what current Xcode accepts.
mkdir -p "$KIT/compat"
printf '/* Classic Mac OS floating-point header, wanted by old libpng. */\n#include <math.h>\n' > "$KIT/compat/fp.h"
#
#    Umbra plays local files and its own loopback stream only, so the network-protocol clients
#    and servers are left out: RTSP (live555, which is LGPLv3), SMB (libdsm, libsmb2), NFS, SFTP
#    (libssh2), UPnP, Icecast output (libshout) and Chromecast (protobuf). Fewer licences to honour,
#    a smaller framework and less attack surface. HTTP access stays: the vault streams over it.
NO_NETWORK_CONTRIBS="--disable-live555 --disable-nfs --disable-ssh2 --disable-shout --disable-protobuf"
NO_NETWORK_MODULES="--disable-nfs --disable-sftp --disable-shout --disable-chromecast --disable-upnp --disable-dsm --disable-microdns"
#
#    GPL code is left out (see the top): zvbi is disabled in the contribs and in configure, and
#    the GPL modules are added to upstream's module blacklist by exact archive name (the
#    blacklist matches substrings, and "dummy" alone would also remove the LGPL vdummy, adummy,
#    mux_dummy ...). The list is scripts/build-libvlc-android.sh's, plus zvbi (an archive left by
#    an earlier build would otherwise still be linked) and without deinterlace (kept, patched).
#    Most are not built for Apple at all; removing them by name keeps them out if they ever are.
GPL_MODULES="access_realrtsp lua mono dolby_surround_decoder headphone_channel_mixer rotate stream_out_rtp stream_out_cycle vod_rtsp file_logger syslog dummy mpc hqdn3d i420_rgb_mmx zvbi"
NO_GPL_MODULES="--disable-zvbi"
GPL_BLACKLIST="$(for m in $GPL_MODULES; do printf '\\n    lib%s_plugin.' "$m"; done)"
COMPAT_CFLAGS="-I$KIT/compat -Dfdopen=fdopen -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-function-pointer-types -Wno-error=incompatible-pointer-types"
sed -e 's/^shift \$((\$OPTIND - 1))$/&\nif [ "$MACOS" = "yes" ]; then BUILD_SIMULATOR=no; fi/' \
    -e "s|^    EXTRA_CFLAGS=\"-isysroot \${SDKROOT}\"$|    EXTRA_CFLAGS=\"-isysroot \${SDKROOT} $COMPAT_CFLAGS\"|" \
    -e 's|^\( *\)IPHONEOS_DEPLOYMENT_TARGET=\${SDK_MIN} \\$|&\n\1MACOSX_DEPLOYMENT_TARGET=14.0 \\|' \
    -e 's/--enable-live555/--disable-live555/; s/--enable-realrtsp/--disable-realrtsp/' \
    -e 's/--enable-upnp/--disable-upnp/; s/--enable-libdsm/--disable-libdsm/; s/--enable-smb2/--disable-smb2/' \
    -e "s|^\(        CUSTOMOSOPTIONS=\"--disable-fontconfig[^\"]*\)\"$|\1 $NO_NETWORK_CONTRIBS\"|" \
    -e "s|^\( *\)--disable-addonmanagermodules \\\\$|&\n\1$NO_NETWORK_MODULES $NO_GPL_MODULES \\\\|" \
    -e 's/^\( *\)--enable-zvbi \\$/\1--disable-zvbi \\/' \
    -e "s|^    hqdn3d\$|&$GPL_BLACKLIST|" \
    buildMobileVLCKit.sh > buildUmbraVLCKit.sh
grep -q 'BUILD_SIMULATOR=no; fi' buildUmbraVLCKit.sh && grep -q -- '-Dfdopen=fdopen' buildUmbraVLCKit.sh \
  && grep -q 'MACOSX_DEPLOYMENT_TARGET=14.0' buildUmbraVLCKit.sh \
  && grep -q -- "$NO_NETWORK_CONTRIBS" buildUmbraVLCKit.sh && grep -q -- "$NO_NETWORK_MODULES $NO_GPL_MODULES" buildUmbraVLCKit.sh \
  && ! grep -qE -- '--enable-(live555|upnp|libdsm|smb2|zvbi)' buildUmbraVLCKit.sh \
  && grep -qE -- '^ +--disable-zvbi \\$' buildUmbraVLCKit.sh \
  && grep -q '^    libdummy_plugin\.$' buildUmbraVLCKit.sh && grep -q '^    libzvbi_plugin\.$' buildUmbraVLCKit.sh \
  || { echo "error: could not adapt buildMobileVLCKit.sh" >&2; exit 1; }
chmod +x buildUmbraVLCKit.sh

# Licence gates (see the top). Before a framework is published to $OUT, every source file
# compiled into the libVLC it links is checked for a GPL header; after, the framework binary is
# checked for GPL modules, GPL code and patent-pool decoders. The report, written only when both
# pass, records the checksum of each binary it covers: scripts/build-mac.sh refuses to embed a
# framework without a matching report.
audit_libvlc_sources() { # report platform... (install-<platform>/arm64, e.g. MacOSXOS)
  local report="$1" p inst; shift
  : > "$report"
  for p in "$@"; do
    inst="libvlc/vlc/install-$p/arm64"
    [[ -d "$inst/lib/vlc/plugins" ]] || { echo "error: no libVLC install at $inst" >&2; exit 1; }
    python3 "$ROOT/scripts/audit-libvlc-sources.py" libvlc/vlc "libvlc/vlc/build-$p/arm64" "$inst/lib/vlc/plugins" \
      --core "$inst/lib/libvlc.a" --core "$inst/lib/libvlccore.a" --core "$inst/lib/vlc/libcompat.a" \
      --report "$report.$p" \
      || { echo "error: GPL code in the $p libVLC (above); nothing was published to $OUT" >&2; exit 1; }
    { echo "[$p arm64]"; cat "$report.$p"; } >> "$report"
    rm -f "$report.$p"
  done
}
write_licence_report() { # xcframework binary-name source-report binary-report -> <name>.licence-audit.txt
  local xcf="$1" name="$2" out="$OUT/$2.licence-audit.txt" bin
  {
    echo "Umbra $name licence audit: VLCKit $VLCKIT_REF, libvlc $TESTED_HASH, Umbra patches: $(cd "$ROOT/scripts/vlc-patches" && ls -- *.patch | tr '\n' ' ')"
    cat "$3" "$4"
    find "$xcf" -type f -name "$name" | sort | while IFS= read -r bin; do
      echo "binary-sha256 $(shasum -a 256 "$bin" | cut -d' ' -f1) ${bin#"$xcf"/}"
    done
  } > "$out"
  grep -q '^binary-sha256 ' "$out" || { echo "error: no $name binary in $xcf" >&2; rm -f "$out"; exit 1; }
  rm -f "$3" "$4"
  echo "licence audit report: $out"
}

if [[ "$TARGET_OS" == "macos" ]]; then
  # -x: macOS   -a aarch64: Apple Silicon only   -n: sources already fetched above
  ./buildUmbraVLCKit.sh -x -a aarch64 -n

  FRAMEWORK="$(find build -path '*VLCKit-macosx.xcarchive/Products/Library/Frameworks/VLCKit.framework' -type d | head -1)"
  [[ -n "$FRAMEWORK" ]] || { echo "error: VLCKit.framework not produced" >&2; exit 1; }

  rm -f "$OUT/VLCKit.licence-audit.txt"
  audit_libvlc_sources "$WORK/VLCKit.source-audit.txt" MacOSXOS

  rm -rf "$OUT/VLCKit.xcframework"
  xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$OUT/VLCKit.xcframework"

  # Gate: refuse to ship if any GPL symbol or encumbered software decoder slipped through.
  "$ROOT/scripts/audit-gpl-symbols.sh" "$OUT/VLCKit.xcframework" | tee "$WORK/VLCKit.binary-audit.txt"
  write_licence_report "$OUT/VLCKit.xcframework" VLCKit "$WORK/VLCKit.source-audit.txt" "$WORK/VLCKit.binary-audit.txt"
  echo "VLCKit ready at $OUT/VLCKit.xcframework (ref $VLCKIT_REF)"
  exit 0
fi

# 4. iOS / iPadOS: MobileVLCKit from the same libvlc tree, patches and configuration as above
#    (the FFmpeg policy and the GPL and network exclusions are shared), adapted once more:
#      * the iOS contrib bootstrap gets the same network-contrib exclusions as macOS (upstream
#        passes no extra options there);
#      * the framework is archived for iOS 17, the app's minimum (upstream's 9.0 is below what
#        current Xcode accepts), as the macOS framework is for macOS 14; libvlc itself keeps
#        upstream's minimum, as on macOS;
#      * with "-a aarch64" upstream builds libvlc for the simulator too but archives only the
#        device framework (its simulator test looks for an Intel architecture); the copy
#        archives the arm64 simulator framework as well, so the app also runs in the Simulator.
#    The app must embed MobileVLCKit as a dynamic framework and never link libvlc statically:
#    that is what keeps the app itself outside the LGPL. VideoLAN's own MobileVLCKit 3.x
#    packages appear to be static (their podspec has apps link libvlc's system libraries), so
#    the check below refuses anything but a dynamic library rather than trusting the project.
sed -e "s|^        CUSTOMOSOPTIONS=\"\"$|        CUSTOMOSOPTIONS=\"$NO_NETWORK_CONTRIBS\"|" \
    -e 's|IPHONEOS_DEPLOYMENT_TARGET=\${SDK_MIN} \\$|IPHONEOS_DEPLOYMENT_TARGET=17.0 \\|' \
    -e 's/^    if \[ "\$FARCH" = "all" \] || (is_simulator_arch \$arch);then$/    if [ "$FARCH" = "all" ] || [ "$BUILD_SIMULATOR" = "yes" ] || (is_simulator_arch $arch);then/' \
    buildUmbraVLCKit.sh > buildUmbraMobileVLCKit.sh
grep -q "CUSTOMOSOPTIONS=\"$NO_NETWORK_CONTRIBS\"" buildUmbraMobileVLCKit.sh \
  && grep -q 'IPHONEOS_DEPLOYMENT_TARGET=17.0' buildUmbraMobileVLCKit.sh \
  && ! grep -q 'IPHONEOS_DEPLOYMENT_TARGET=\${SDK_MIN}' buildUmbraMobileVLCKit.sh \
  && grep -q '\[ "\$BUILD_SIMULATOR" = "yes" \] || (is_simulator_arch' buildUmbraMobileVLCKit.sh \
  || { echo "error: could not adapt buildMobileVLCKit.sh for iOS" >&2; exit 1; }
chmod +x buildUmbraMobileVLCKit.sh
# (no -x): iOS   -a aarch64: arm64 device + arm64 simulator   -n: sources already fetched above
./buildUmbraMobileVLCKit.sh -a aarch64 -n

DEVICE_FW="build/MobileVLCKit-iphoneos.xcarchive/Products/Library/Frameworks/MobileVLCKit.framework"
SIM_FW="build/MobileVLCKit-iphonesimulator.xcarchive/Products/Library/Frameworks/MobileVLCKit.framework"
for fw in "$DEVICE_FW" "$SIM_FW"; do
  [[ -f "$fw/MobileVLCKit" ]] || { echo "error: $fw not produced" >&2; exit 1; }
  # A static framework would put libvlc inside the app's own binary: refuse it.
  file "$fw/MobileVLCKit" | grep -q 'dynamically linked shared library' \
    || { echo "error: $fw is not a dynamic framework: $(file -b "$fw/MobileVLCKit")" >&2
         echo "       linking it would put libvlc into the app binary (LGPL); build the MobileVLCKit" >&2
         echo "       target as a dynamic library (MACH_O_TYPE=mh_dylib) before shipping it" >&2; exit 1; }
  [[ "$(lipo -archs "$fw/MobileVLCKit")" == "arm64" ]] \
    || { echo "error: $fw is not arm64-only: $(lipo -archs "$fw/MobileVLCKit")" >&2; exit 1; }
done

rm -f "$OUT/MobileVLCKit.licence-audit.txt"
audit_libvlc_sources "$WORK/MobileVLCKit.source-audit.txt" iPhoneOS iPhoneSimulator

rm -rf "$OUT/MobileVLCKit.xcframework"
xcodebuild -create-xcframework -framework "$DEVICE_FW" -framework "$SIM_FW" -output "$OUT/MobileVLCKit.xcframework"

# Same gates as for the Mac framework.
"$ROOT/scripts/audit-gpl-symbols.sh" "$OUT/MobileVLCKit.xcframework" | tee "$WORK/MobileVLCKit.binary-audit.txt"
write_licence_report "$OUT/MobileVLCKit.xcframework" MobileVLCKit "$WORK/MobileVLCKit.source-audit.txt" "$WORK/MobileVLCKit.binary-audit.txt"
echo "MobileVLCKit ready at $OUT/MobileVLCKit.xcframework (ref $VLCKIT_REF)"
