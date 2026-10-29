#!/usr/bin/env bash
# Builds Umbra's LGPL-only libVLC for Android and packages it as the AAR the app's release build
# picks up (App/UmbraAndroid/libvlc/libvlc-lgpl.aar, gitignored; see App/UmbraAndroid/README.md).
# The same rules as the Mac/iPhone engine (scripts/build-vlckit.sh, docs/COMPLIANCE.md §1.3, §2):
#   * contribs bootstrapped with --disable-gpl --disable-gnuv3 (VideoLAN's "--license a", LGPL
#     2.1): no liba52, libdca, faad2, libmad, libmpeg2, x262, x264, x265, libdvdcss, libdvdnav,
#     libdvdread, libsamplerate, sidplay2, aribb24, vncclient, and no GnuTLS/Nettle/GMP (LGPLv3 or
#     GPL), so libVLC has no TLS of its own: https goes through Media3 (see the README);
#   * FFmpeg without --enable-gpl/--enable-nonfree and without libpostproc, and without a software
#     decoder for any codec whose patent pool still licenses (docs/COMPLIANCE.md §2; owner decision
#     2026-10-29: no royalties): h264, hevc, ac4, truehd, mlp, aac, aac_fixed, aac_latm, dca (DTS),
#     vc1, vc1image, wmv3, wmv3image and mss2 (VC-1/WMV9). Android decodes those through
#     MediaCodec: Media3 first, and libVLC's own mediacodec module (its audio part turned on by
#     LibVlcGuard.OPTIONS, "--mediacodec-audio"), so AAC still plays in libVLC; DTS and VC-1 play
#     only where the phone has a decoder for them;
#   * VLC's own GPL modules left out (lua, realrtsp, mono, dolby_surround_decoder,
#     headphone_channel_mixer, rotate, stream_out_rtp/cycle, vod_rtsp, file_logger, syslog, the
#     dummy interface and the ones upstream already drops), and the modules whose sources carry GPL
#     headers without declaring it (hqdn3d, i420_rgb_mmx); zvbi (mixed GPL/LGPL) left out;
#   * the deinterlace module kept without yadif, whose yadif.h/yadif_template.h are GPL
#     (scripts/vlc-patches-android/0002, the Mac's scripts/vlc-patches/0002; the yadif files are
#     deleted from the tree too), so interlaced video through libVLC is deinterlaced ("x");
#   * network clients Umbra does not need left out, as on the Mac: SMB (libdsm, libsmb2), NFS,
#     SFTP, UPnP, microdns, RTSP (live555), Chromecast; and Game Music Emu (chiptune formats; its
#     tarball is only on GitHub, which the build host may not reach);
#   * scripts/vlc-patches-android/*.patch applied (0001: never proxy a loopback URL; 0002: the
#     deinterlace module without yadif);
#   * libvlcjni without renderer discovery: RendererDiscoverer.java, its only GPL-headed source,
#     is deleted with its JNI side, and scripts/libvlcjni-patches/0001 removes what referred to it
#     (docs/COMPLIANCE.md §1.4; Umbra never casts);
#   * audited at the end (scripts/audit-android-libvlc.sh, the licence header of every source file
#     compiled into the linked modules and core (scripts/audit-libvlc-sources.py), the licence of
#     every VLC module and FFmpeg's own licence string); any hit fails the build.
#
#   ANDROID_NDK=/path/to/android-ndk-r28c scripts/build-libvlc-android.sh            # arm64-v8a x86_64
#   ABIS=arm64-v8a ANDROID_NDK=… scripts/build-libvlc-android.sh                     # one ABI
#   PACKAGE_ONLY=1 scripts/build-libvlc-android.sh     # re-package the ABIs already staged
#
# Needs Linux (GNU sed: this script and upstream's build scripts use GNU-only sed syntax, so a
# macOS host stops at the start; on a Mac use a Linux VM) with: NDK r27 or r28 (upstream's compile-libvlc.sh refuses others; r28c =
# 28.2.13676358 is what VideoLAN used for 3.6.5), the Android SDK (platform 36), JDK 17, git, curl
# or wget, make, gcc/clang for the host, pkg-config, autoconf, automake, cmake, ninja, nasm,
# python3, bison, flex, gettext/autopoint, libtool with libltdl (ltdl.m4: Debian/Ubuntu libtool-bin
# and libltdl-dev; mpg123 needs LT_SYS_MODULE_EXT), unzip, xz, bzip2 (libvlc's extras/tools builds what is
# too old). Disk: about 2.5 GB for sources and tarballs, plus about 4 GB per ABI while it builds
# (KEEP_BUILD_TREES=0, the default, deletes each contrib's build tree once it is installed and the
# ABI's whole build tree once its libraries are staged). Time: 1–3 hours per ABI on 4 cores.
# Re-running resumes where it stopped.
#
# Output: $OUT (default App/UmbraAndroid/libvlc/libvlc-lgpl.aar) with jni/<abi>/libvlc.so,
# libvlcjni.so and libc++_shared.so, the org.videolan.libvlc classes and resources, and
# assets/hrtfs; plus $WORK/report/ (FFmpeg decoders, VLC modules, audit output per ABI).
set -euo pipefail

# GNU sed only (see the header): BSD sed fails deep inside the build with an obscure error.
sed --version 2>/dev/null | grep -q 'GNU sed' || { echo "error: needs GNU sed (build on Linux; on a Mac use a Linux VM)" >&2; exit 1; }

VLC_ANDROID_TAG="${VLC_ANDROID_TAG:-libvlc-3.6.5}"
# The commit that tag names (a tag can move; the libvlcjni and VLC commits are read from it).
VLC_ANDROID_COMMIT="${VLC_ANDROID_COMMIT:-c85e5c1fd74c8e4182eaef56349976c96cebdc76}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_APP="$ROOT/App/UmbraAndroid"
WORK="${WORK:-$ANDROID_APP/libvlc/build}"
OUT="${OUT:-$ANDROID_APP/libvlc/libvlc-lgpl.aar}"
ABIS="${ABIS:-arm64-v8a x86_64}"
KEEP_BUILD_TREES="${KEEP_BUILD_TREES:-0}"
MIN_FREE_GB="${MIN_FREE_GB:-3}"
PACKAGE_ONLY="${PACKAGE_ONLY:-0}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "== $*" >&2; }

# Stops before the disk fills up (the build area may be shared).
check_disk() {
  local free_kb
  free_kb="$(df -Pk "$WORK" | awk 'NR==2 {print $4}')"
  if [[ "$free_kb" -lt $((MIN_FREE_GB * 1024 * 1024)) ]]; then
    die "less than $MIN_FREE_GB GB free on $(df -P "$WORK" | awk 'NR==2 {print $6}') ($((free_kb / 1024)) MB); stopping (resume later, or set MIN_FREE_GB)"
  fi
}

SDK="${ANDROID_SDK:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
if [[ -z "$SDK" && -f "$ANDROID_APP/local.properties" ]]; then
  SDK="$(sed -n 's/^sdk\.dir=//p' "$ANDROID_APP/local.properties")"
fi
[[ -n "$SDK" && -d "$SDK/platforms" ]] || die "set ANDROID_HOME (or ANDROID_SDK) to the Android SDK"
export ANDROID_SDK="$SDK" ANDROID_HOME="$SDK"

mkdir -p "$WORK" "$WORK/report" "$WORK/jniLibs"
WORK="$(cd "$WORK" && pwd)"
cd "$WORK"

# 1. Sources: vlc-android at the tag of this libVLC release, the libvlcjni commit it pins, and
#    the VLC 3.0.x commit libvlcjni pins, with libvlcjni's own VLC patches (git am --message-id,
#    which its get-vlc.sh checks for) and then Umbra's. Only build configuration changes beyond
#    scripts/vlc-patches-android, which is published with this script (LGPL).
fetch_commit() { # dir url commit
  local dir="$1" url="$2" commit="$3"
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    local i
    for i in 1 2 3; do git -C "$dir" fetch -q --depth 1 origin "$commit" && break; sleep 10; done
    git -C "$dir" cat-file -e "$commit^{commit}" || die "could not fetch $url $commit"
  fi
}

if [[ ! -d vlc-android/.git ]]; then
  git clone -q --depth 1 --branch "$VLC_ANDROID_TAG" https://code.videolan.org/videolan/vlc-android.git vlc-android
fi
got="$(git -C vlc-android rev-parse HEAD)"
[[ "$got" == "$VLC_ANDROID_COMMIT" ]] \
  || die "vlc-android $VLC_ANDROID_TAG is $got, expected $VLC_ANDROID_COMMIT (set VLC_ANDROID_COMMIT for another tag)"
LIBVLCJNI_HASH="$(sed -n '/FORCE_VLC_4" = 1/,/^fi/{/else/,/^fi/s/^ *LIBVLCJNI_TESTED_HASH=\([0-9a-f]*\).*/\1/p}' vlc-android/buildsystem/compile.sh)"
LIBVLCJNI_URL="$(sed -n 's/^LIBVLCJNI_REPOSITORY=\(.*\)$/\1/p' vlc-android/buildsystem/compile.sh)"
[[ "$LIBVLCJNI_HASH" =~ ^[0-9a-f]{40}$ && -n "$LIBVLCJNI_URL" ]] || die "could not read the libvlcjni commit from vlc-android/buildsystem/compile.sh"

if [[ ! -f libvlcjni/buildsystem/compile-libvlc.sh ]]; then
  fetch_commit libvlcjni "$LIBVLCJNI_URL" "$LIBVLCJNI_HASH"
  git -C libvlcjni checkout -q "$LIBVLCJNI_HASH"
fi
JNI="$WORK/libvlcjni"

# 1a. libvlcjni without renderer discovery (docs/COMPLIANCE.md §1.4): RendererDiscoverer.java is
#     the only libvlcjni source with a GPL header (GPL 2+; the rest is LGPL 2.1+ or has no header).
#     Umbra never casts, so the class and its JNI side (libvlcjni-rendererdiscoverer.c, LGPL, used
#     by nothing else) are deleted, and scripts/libvlcjni-patches/0001 removes what referred to
#     them (JNI_OnLoad's class lookups, Android.mk, utils.h). Applied to the working tree like
#     Umbra's VLC patches below; scripts/audit-android-libvlc.sh fails on the class, on a
#     libvlcjni.so that still looks it up, and on any GPL-headed Java/Kotlin source.
JNI_PATCHES=()
for patch in "$ROOT"/scripts/libvlcjni-patches/*.patch; do
  if [[ -f "$patch" ]]; then JNI_PATCHES+=("$patch"); fi
done
(( ${#JNI_PATCHES[@]} > 0 )) || die "no patches in scripts/libvlcjni-patches"
jni_patches_current=1
for patch in "${JNI_PATCHES[@]}"; do
  (cd "$JNI" && git apply --reverse --check "$patch" >/dev/null 2>&1) || jni_patches_current=0
done
if (( jni_patches_current == 0 )); then
  for patch in "${JNI_PATCHES[@]}"; do
    (cd "$JNI" && git apply --numstat "$patch" | cut -f3 | while IFS= read -r file; do
      git checkout -q HEAD -- "$file" || exit 1; done) \
      || die "could not restore the libvlcjni files $(basename "$patch") touches"
  done
  for patch in "${JNI_PATCHES[@]}"; do
    (cd "$JNI" && git apply "$patch") || die "could not apply $(basename "$patch") to libvlcjni"
  done
fi
rm -f "$JNI/libvlc/src/org/videolan/libvlc/RendererDiscoverer.java" "$JNI/libvlc/jni/libvlcjni-rendererdiscoverer.c"
jni_sources=(--include='*.java' --include='*.kt' --include='*.c' --include='*.h' --include='*.mk')
! grep -rqI "${jni_sources[@]}" RendererDiscoverer "$JNI/libvlc/src" "$JNI/libvlc/jni" \
  || die "libvlcjni still refers to RendererDiscoverer: $(grep -rlI "${jni_sources[@]}" RendererDiscoverer "$JNI/libvlc/src" "$JNI/libvlc/jni" | tr '\n' ' ')"
# Every Java/Kotlin source that goes into the AAR: no GPL header (fails before hours of building).
"$ROOT/scripts/audit-android-libvlc.sh" "$JNI/libvlc/src" > "$WORK/report/java-source-audit.txt" \
  || { cat "$WORK/report/java-source-audit.txt" >&2; die "GPL Java/Kotlin source in libvlcjni (above)"; }

VLC_HASH="$(sed -n 's/^VLC_TESTED_HASH=\([0-9a-f]*\)$/\1/p' "$JNI/buildsystem/get-vlc.sh")"
VLC_URL="$(sed -n 's/^VLC_REPOSITORY=\(.*\)$/\1/p' "$JNI/buildsystem/get-vlc.sh")"
[[ "$VLC_HASH" =~ ^[0-9a-f]{40}$ && -n "$VLC_URL" ]] || die "could not read VLC_TESTED_HASH from libvlcjni/buildsystem/get-vlc.sh"

VLC="$JNI/vlc"
if [[ ! -f "$VLC/.umbra-upstream-patches" ]]; then
  fetch_commit "$VLC" "$VLC_URL" "$VLC_HASH"
  git -C "$VLC" checkout -q -B umbra "$VLC_HASH"
  git -C "$VLC" -c user.name=umbra-build -c user.email=build@localhost am -q --message-id "$JNI"/libvlc/patches/*.patch
  touch "$VLC/.umbra-upstream-patches"
fi
# Umbra's patches are applied to the working tree, never committed. When they are not all
# applied as they are now (a fresh tree, or one patched by an earlier version of a patch), the
# files they touch are restored from HEAD (VLC + libvlcjni's patches) and all reapplied.
UMBRA_PATCHES=()
for patch in "$ROOT"/scripts/vlc-patches-android/*.patch; do
  if [[ -f "$patch" ]]; then UMBRA_PATCHES+=("$patch"); fi
done
if (( ${#UMBRA_PATCHES[@]} > 0 )); then
  umbra_patches_current=1
  for patch in "${UMBRA_PATCHES[@]}"; do
    (cd "$VLC" && git apply --reverse --check "$patch" >/dev/null 2>&1) || umbra_patches_current=0
  done
  if (( umbra_patches_current == 0 )); then
    for patch in "${UMBRA_PATCHES[@]}"; do
      (cd "$VLC" && git apply --numstat "$patch" | cut -f3 | while IFS= read -r file; do
        git checkout -q HEAD -- "$file" || exit 1; done) \
        || die "could not restore the files $(basename "$patch") touches"
    done
    for patch in "${UMBRA_PATCHES[@]}"; do
      (cd "$VLC" && git apply "$patch") || die "could not apply $(basename "$patch")"
    done
    # A patch that changes a Makefile.am needs fresh Makefile.in files (an earlier bootstrap's
    # would still list what it removed); compile-libvlc.sh bootstraps VLC when configure is missing.
    rm -f "$VLC/configure"
  fi
fi
# yadif's GPL files are deleted too (0002 already stops building them), so that no later change
# to the build can compile them back in.
DEINTERLACE="$VLC/modules/video_filter/deinterlace"
rm -f "$DEINTERLACE/algo_yadif.c" "$DEINTERLACE/algo_yadif.h" "$DEINTERLACE/yadif.h" "$DEINTERLACE/yadif_template.h"
! grep -q yadif "$VLC/modules/video_filter/Makefile.am" && [[ -f "$DEINTERLACE/algo_x.c" ]] \
  || die "the deinterlace module still lists yadif (scripts/vlc-patches-android/0002 not applied?)"
echo "vlc-android $VLC_ANDROID_TAG, libvlcjni $LIBVLCJNI_HASH, vlc $VLC_HASH" > "$WORK/report/sources.txt"

# 2. FFmpeg policy (as scripts/build-vlckit.sh): make expands FFMPEGCONF when the recipe runs,
#    so appending to the rules is enough. --disable-gpl also leaves libpostproc out. A tree
#    configured with another policy (an earlier version of this script) gets the current line
#    instead, and its FFmpeg contribs are rebuilt (the contrib system does not rebuild a package
#    when only its rules.mak changes; KEEP_BUILD_TREES=0 deletes them after each ABI anyway).
#    The V4L2 mem2mem wrappers for H.264, HEVC and VC-1 go too: no Android app can open a V4L2
#    device, and the release audit refuses them like the decoders. So do the software encoders of
#    the same pools (aac, dca, truehd, mlp): the patent licences cover encoders as well, and Umbra
#    never encodes through libVLC (recording copies the stream; thumbnails are raw frames).
NO_FFMPEG_DECODERS="h264 hevc ac4 truehd mlp aac aac_fixed aac_latm dca vc1 vc1image wmv3 wmv3image mss2 h264_v4l2m2m hevc_v4l2m2m vc1_v4l2m2m"
NO_FFMPEG_ENCODERS="aac dca truehd mlp"
FFMPEG_POLICY="FFMPEGCONF += --disable-gpl --disable-nonfree --disable-postproc$(for d in $NO_FFMPEG_DECODERS; do printf ' --disable-decoder=%s' "$d"; done)$(for e in $NO_FFMPEG_ENCODERS; do printf ' --disable-encoder=%s' "$e"; done)"
RULES="$VLC/contrib/src/ffmpeg/rules.mak"
if ! grep -qxF -- "$FFMPEG_POLICY" "$RULES"; then
  awk '/^# Umbra LGPL\/patent policy$/ {exit} {print}' "$RULES" > "$RULES.umbra" && mv "$RULES.umbra" "$RULES"
  printf '\n# Umbra LGPL/patent policy\n%s\n' "$FFMPEG_POLICY" >> "$RULES"
  for stamp in "$VLC"/contrib/*/.ffmpeg; do
    if [[ -f "$stamp" ]]; then rm -rf "$stamp" "$(dirname "$stamp")/ffmpeg"; fi
  done
fi
grep -qxF -- "$FFMPEG_POLICY" "$RULES" && [[ "$(grep -c '^# Umbra LGPL/patent policy$' "$RULES")" == 1 ]] \
  || die "could not write the FFmpeg policy to $RULES"
NO_FFMPEG_DECODERS_RE="^($(echo "$NO_FFMPEG_DECODERS" | tr ' ' '|'))$"

# 3. A copy of libvlcjni's compile-libvlc.sh, adapted (build configuration only):
#      * no -g (debug info would take several GB; ndk-build strips the shipped .so anyway);
#      * contribs: the network clients, zvbi, lua and the GPL-only ones disabled explicitly
#        (--license a already drops the GPL ones);
#      * configure: no realrtsp (GPL), lua (GPL), zvbi, SMB, NFS, SFTP, UPnP, microdns, live555,
#        Chromecast, DVD, and none of the GPL decoders (the line after --enable-sout, which only
#        the configure list has: --enable-smb2 is in both lists);
#      * the GPL VLC modules added to upstream's module blacklist;
#      * -lgpg-error after the contribs' link flags: libgcrypt.pc requires gpg-error, but the
#        contribs' libgpg-error 1.27 installs no gpg-error.pc, so pkg-config leaves it out and
#        libvlc.so fails to link (gpgrt_*, gpg_strerror undefined);
#      * contribs built one package at a time, each build tree deleted once installed, with the
#        disk checked in between (make_contribs below).
#      * libvpx left out (upstream's --enable-vpx becomes --disable-vpx below): vlc-android sets
#        LD=<ndk>/bin/llvm-ld, which no NDK since r23 ships, and libvpx is the only contrib that
#        links with $LD (its configure stops with "Toolchain is unable to link executables").
#        VP8/VP9 still decode through FFmpeg's own (LGPL) decoders in libVLC, and Media3 plays
#        VP9 natively first.
NO_CONTRIBS="--disable-upnp --disable-libdsm --disable-smb2 --disable-nfs --disable-microdns --disable-zvbi --disable-live555 --disable-ssh2 --disable-shout --disable-protobuf --disable-dvdcss --disable-dvdnav --disable-dvdread --disable-a52 --disable-dca --disable-faad2 --disable-mad --disable-libmpeg2 --disable-x262 --disable-x264 --disable-x265 --disable-samplerate --disable-sidplay2 --disable-aribb24 --disable-vncclient --disable-gnutls --disable-nettle --disable-gmp"
NO_MODULES="--disable-dsm --disable-nfs --disable-sftp --disable-upnp --disable-microdns --disable-live555 --disable-chromecast --disable-dvdread --disable-dvdnav --disable-a52 --disable-libmpeg2 --disable-x264 --disable-x265 --disable-faad --disable-postproc --disable-shout --disable-gnutls"
# The first ones declare VLC_LICENSE_GPL_2_PLUS. The last two do not, but their code is GPL:
# hqdn3d.h (from MPlayer; FFmpeg's hqdn3d is GPL too) and i420_rgb_mmx.h (x86 only; i420_rgb and
# i420_rgb_sse2 are LGPL). deinterlace is not here: its only GPL files are yadif.h and
# yadif_template.h (FFmpeg's yadif under its old GPL header), which patch 0002 stops building.
GPL_MODULES="access_realrtsp lua mono dolby_surround_decoder headphone_channel_mixer rotate stream_out_rtp stream_out_cycle vod_rtsp file_logger syslog dummy mpc hqdn3d i420_rgb_mmx"
COMPILE="$JNI/buildsystem/compile-libvlc-umbra.sh"
sed -e 's/^     VLC_CFLAGS="-g -O2"$/     VLC_CFLAGS="-O2"/' \
    -e 's/^    --enable-upnp \\$/    --disable-upnp \\/' \
    -e 's/^    --enable-libdsm \\$/    --disable-libdsm \\/' \
    -e 's/^    --enable-smb2 \\$/    --disable-smb2 \\/' \
    -e 's/^    --enable-nfs \\$/    --disable-nfs \\/' \
    -e 's/^    --enable-microdns \\$/    --disable-microdns \\/' \
    -e 's/^    --enable-zvbi \\$/    --disable-zvbi \\/' \
    -e 's/^    --enable-lua \\$/    --disable-lua \\/' \
    -e 's/^    --enable-realrtsp \\$/    --disable-realrtsp \\/' \
    -e 's/^    --enable-gme \\$/    --disable-gme \\/' \
    -e 's/^    --enable-vpx \\$/    --disable-vpx \\/' \
    -e "s/^    --disable-medialibrary \\\\\$/&\n    $NO_CONTRIBS \\\\/" \
    -e "s/^    --enable-sout \\\\\$/&\n    $NO_MODULES \\\\/" \
    -e "s/^    \.dummy\$/&\n    $(echo "$GPL_MODULES" | sed 's/ /\\n    /g')/" \
    -e 's|^    make -C \$VLC_CONTRIB_DIR TARBALLS="\$VLC_TARBALLS" \$MAKEFLAGS fetch$|    umbra_fetch_contribs|' \
    -e 's|^VLC_CONTRIB_LDFLAGS=\$(cd \$VLC_CONTRIB/lib/pkgconfig; .*$|&\n[ -f "$VLC_CONTRIB/lib/libgpg-error.a" ] \&\& VLC_CONTRIB_LDFLAGS="$VLC_CONTRIB_LDFLAGS -lgpg-error"|' \
    -e 's|^    make -C \$VLC_CONTRIB_DIR TARBALLS="\$VLC_TARBALLS" \$MAKEFLAGS -k \|\| make -C \$VLC_CONTRIB_DIR TARBALLS="\$VLC_TARBALLS" \$MAKEFLAGS -j1$|    umbra_make_contribs|' \
    "$JNI/buildsystem/compile-libvlc.sh" > "$COMPILE.tmp"
# The two contrib helpers, defined before avlc_build runs (sourced from the environment).
grep -q 'VLC_CFLAGS="-O2"' "$COMPILE.tmp" \
  && grep -q -- "$NO_CONTRIBS" "$COMPILE.tmp" && grep -q -- "$NO_MODULES" "$COMPILE.tmp" \
  && grep -q '^    file_logger$' "$COMPILE.tmp" && grep -q '^    i420_rgb_mmx$' "$COMPILE.tmp" \
  && grep -q '^    umbra_fetch_contribs$' "$COMPILE.tmp" \
  && grep -q '^    umbra_make_contribs$' "$COMPILE.tmp" \
  && grep -q 'VLC_CONTRIB_LDFLAGS -lgpg-error' "$COMPILE.tmp" \
  && ! grep -qE -- '^    --enable-(upnp|libdsm|smb2|nfs|microdns|zvbi|lua|realrtsp|gme|vpx) \\$' "$COMPILE.tmp" \
  || die "could not adapt libvlcjni/buildsystem/compile-libvlc.sh (upstream changed?)"
{
  echo '#!/bin/sh'
  echo '. "$UMBRA_HELPERS"'
  tail -n +2 "$COMPILE.tmp"
} > "$COMPILE"
rm -f "$COMPILE.tmp"
chmod +x "$COMPILE"

cat > "$JNI/buildsystem/umbra-helpers.sh" <<'HELPERS'
# Sourced by compile-libvlc-umbra.sh (POSIX sh). Variables come from compile-libvlc.sh.
umbra_free_kb() { df -Pk "$VLC_CONTRIB_DIR" | awk 'NR==2 {print $4}'; }
umbra_check_disk() {
    if [ "$(umbra_free_kb)" -lt $((UMBRA_MIN_FREE_GB * 1024 * 1024)) ]; then
        echo "error: less than $UMBRA_MIN_FREE_GB GB free; stopping (resume later)" >&2
        exit 1
    fi
}
umbra_pkgs() {
    make -s -C "$VLC_CONTRIB_DIR" -f Makefile -f "$UMBRA_PRINT_MK" TARBALLS="$VLC_TARBALLS" umbra-print-pkgs
}
# Downloads every tarball, checked against contrib/src/*/SHA512SUMS by the contrib system
# (.sum-<pkg>); retried, since the network may cut transfers.
umbra_fetch_contribs() {
    for attempt in 1 2 3 4; do
        if make -C "$VLC_CONTRIB_DIR" TARBALLS="$VLC_TARBALLS" $MAKEFLAGS fetch; then return 0; fi
        echo "contribs: fetch failed (attempt $attempt), retrying" >&2
        sleep 15
    done
    echo "error: contribs: fetch failed" >&2
    exit 1
}
# Builds the contribs one package at a time (make resolves the dependencies). Unless
# UMBRA_KEEP_BUILD_TREES=1, a package's unpacked build tree is deleted once it is installed, and an
# empty directory with its stamp's date is left in its place, so that make still sees the package
# as built on a re-run (a prerequisite as old as its target is up to date).
umbra_make_contribs() {
    for pkg in $(umbra_pkgs); do
        umbra_check_disk
        make -C "$VLC_CONTRIB_DIR" TARBALLS="$VLC_TARBALLS" $MAKEFLAGS ".$pkg" \
            || make -C "$VLC_CONTRIB_DIR" TARBALLS="$VLC_TARBALLS" -j1 ".$pkg" \
            || { echo "error: contrib $pkg failed" >&2; exit 1; }
        [ "$UMBRA_KEEP_BUILD_TREES" = 1 ] && continue
        for stamp in "$VLC_CONTRIB_DIR"/.[a-z0-9]*; do
            name="${stamp##*/.}"
            case "$name" in sum-*|*.*) continue ;; esac
            dir="$VLC_CONTRIB_DIR/$name"
            [ -f "$stamp" ] && [ -d "$dir" ] || continue
            [ -z "$(ls -A "$dir")" ] && continue
            rm -rf "$dir" && mkdir "$dir" && touch -r "$stamp" "$dir"
        done
    done
    make -C "$VLC_CONTRIB_DIR" TARBALLS="$VLC_TARBALLS" $MAKEFLAGS \
        || { echo "error: contribs: make failed" >&2; exit 1; }
}
HELPERS
printf 'umbra-print-pkgs:\n\t@echo $(PKGS)\n' > "$JNI/buildsystem/umbra-print-pkgs.mk"

find_nm() {
  local t
  for t in "$ANDROID_NDK"/toolchains/llvm/prebuilt/*/bin/llvm-nm; do [[ -x "$t" ]] && { echo "$t"; return; }; done
  die "llvm-nm not found in the NDK"
}

triplet_of() {
  case "$1" in
    arm64-v8a) echo aarch64-linux-android ;;
    x86_64) echo x86_64-linux-android ;;
    armeabi-v7a) echo arm-linux-androideabi ;;
    x86) echo i686-linux-android ;;
    *) die "unknown ABI $1" ;;
  esac
}

# What an ABI was built with: this script and the patches. A staged ABI built with anything else
# is rebuilt, so a change here (a module left out, a contrib disabled) always reaches the AAR.
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
CONFIG_ID="$(cat "$ROOT/scripts/build-libvlc-android.sh" "$ROOT"/scripts/vlc-patches-android/*.patch "$ROOT"/scripts/libvlcjni-patches/*.patch | sha256 | cut -c1-64)"

# 4. Per ABI: build, check, stage.
build_abi() {
  local abi="$1" triplet build_dir
  triplet="$(triplet_of "$abi")"
  build_dir="$VLC/build-android-$triplet"
  if [[ -f "$WORK/jniLibs/$abi/libvlc.so" && -f "$WORK/report/$abi-audit.txt" ]]; then
    if [[ "$(cat "$WORK/report/$abi-config.txt" 2>/dev/null || true)" == "$CONFIG_ID" ]]; then
      log "$abi already staged ($WORK/jniLibs/$abi); delete it to rebuild"
      return
    fi
    log "$abi was staged by another version of this script or its patches: rebuilding it"
    rm -rf "$WORK/jniLibs/$abi" "$WORK/report/$abi-audit.txt"
  fi
  check_disk
  log "building libVLC for $abi"
  log "log: $WORK/report/$abi-build.log"
  local rc=0
  (cd "$JNI" && UMBRA_HELPERS="$JNI/buildsystem/umbra-helpers.sh" UMBRA_PRINT_MK="$JNI/buildsystem/umbra-print-pkgs.mk" \
     UMBRA_KEEP_BUILD_TREES="$KEEP_BUILD_TREES" UMBRA_MIN_FREE_GB="$MIN_FREE_GB" MAKEFLAGS="-j$JOBS" \
     ANDROID_NDK="$ANDROID_NDK" ANDROID_SDK="$SDK" \
     "$COMPILE" -a "$abi" --release --license a) >> "$WORK/report/$abi-build.log" 2>&1 || rc=$?
  [[ $rc -eq 0 ]] || { tail -40 "$WORK/report/$abi-build.log" >&2; die "libVLC build for $abi failed ($rc); see $WORK/report/$abi-build.log"; }

  local libs="$JNI/libvlc/jni/libs/$abi"
  [[ -f "$libs/libvlc.so" && -f "$libs/libvlcjni.so" ]] || die "ndk-build left no libvlc.so/libvlcjni.so in $libs"

  # Licence of every VLC module linked into libvlc.so (the redefined copies are the ones linked).
  local plugins="$build_dir/install/lib/vlc/plugins" gpl="" nm strings_tool
  nm="$(find_nm)"; strings_tool="$(dirname "$nm")/llvm-strings"
  : > "$WORK/report/$abi-modules.txt"
  for a in "$plugins"/lib*_plugin.a; do
    local name="${a##*/lib}"; name="${name%_plugin.a}"
    if "$strings_tool" "$a" | grep -q 'Licensed under the terms of the GNU General Public License'; then gpl="$gpl $name"; fi
    echo "$name" >> "$WORK/report/$abi-modules.txt"
  done
  [[ -z "$gpl" ]] || die "GPL VLC modules would be linked into libvlc.so:$gpl (add them to GPL_MODULES)"
  # Not an empty glob: libVLC links about 240 modules.
  [[ "$(grep -c . "$WORK/report/$abi-modules.txt")" -ge 100 ]] || die "found no VLC modules in $plugins"
  # The blacklist took effect (hqdn3d and i420_rgb_mmx declare no licence).
  local m
  for m in $GPL_MODULES; do
    ! grep -qx "$m" "$WORK/report/$abi-modules.txt" || die "GPL VLC module $m would be linked into libvlc.so"
  done
  # Deinterlacing is linked (patched: LGPL only).
  grep -qx deinterlace "$WORK/report/$abi-modules.txt" || die "the deinterlace module is not linked"
  # Every source file and header compiled into what libvlc.so links: no GPL licence header (this
  # is what finds GPL code in a module that declares no licence, e.g. a yadif left in deinterlace).
  python3 "$ROOT/scripts/audit-libvlc-sources.py" "$VLC" "$build_dir" "$plugins" \
      --core "$build_dir/lib/.libs/libvlc.a" --core "$build_dir/src/.libs/libvlccore.a" \
      --core "$build_dir/compat/.libs/libcompat.a" --report "$WORK/report/$abi-source-audit.txt" \
    || die "GPL source code would be linked into libvlc.so (see $WORK/report/$abi-source-audit.txt)"

  # FFmpeg: its own licence string, and the decoders it was built with.
  local contrib="$VLC/contrib/$triplet"
  "$strings_tool" "$libs/libvlc.so" | grep -E '^lib(avcodec|avformat|avutil|swscale) license: ' | sort -u > "$WORK/report/$abi-ffmpeg-license.txt"
  grep -q '^libavcodec license: LGPL version 2.1 or later$' "$WORK/report/$abi-ffmpeg-license.txt" \
    || die "libavcodec does not report LGPL 2.1+: $(cat "$WORK/report/$abi-ffmpeg-license.txt")"
  ! grep -v ': LGPL version 2.1 or later$' "$WORK/report/$abi-ffmpeg-license.txt" | grep -q . \
    || die "an FFmpeg library is not LGPL: $(cat "$WORK/report/$abi-ffmpeg-license.txt")"
  "$nm" --defined-only "$contrib/lib/libavcodec.a" 2>/dev/null | awk '$2 ~ /^[DdRr]$/ {print $3}' \
    | sed -n 's/^ff_\(.*\)_decoder$/\1/p' | sort -u > "$WORK/report/$abi-ffmpeg-decoders.txt"
  [[ -s "$WORK/report/$abi-ffmpeg-decoders.txt" ]] || die "could not list FFmpeg's decoders"
  if grep -qE "$NO_FFMPEG_DECODERS_RE" "$WORK/report/$abi-ffmpeg-decoders.txt"; then
    die "FFmpeg was built with a decoder it must not have: $(grep -E "$NO_FFMPEG_DECODERS_RE" "$WORK/report/$abi-ffmpeg-decoders.txt" | tr '\n' ' ')"
  fi
  # The decoders that stay (expired pools or none): AC-3/E-AC-3, MPEG-2, MPEG-4 Part 2, MP3, WMV7/8.
  for d in ac3 eac3 mpeg2video mpeg4 mp3 wmv1 wmv2 msmpeg4v3; do
    grep -qx "$d" "$WORK/report/$abi-ffmpeg-decoders.txt" || die "FFmpeg was built without its $d decoder"
  done
  [[ ! -e "$contrib/lib/libpostproc.a" ]] || die "libpostproc was built"

  # The release gate the app runs, on the stripped libraries.
  ANDROID_HOME="$SDK" "$ROOT/scripts/audit-android-libvlc.sh" "$libs" | tee "$WORK/report/$abi-audit.txt.tmp"
  mv "$WORK/report/$abi-audit.txt.tmp" "$WORK/report/$abi-audit.txt"

  rm -rf "$WORK/jniLibs/$abi" && mkdir -p "$WORK/jniLibs/$abi"
  cp "$libs"/libvlc.so "$libs"/libvlcjni.so "$WORK/jniLibs/$abi/"
  [[ -f "$libs/libc++_shared.so" ]] && cp "$libs/libc++_shared.so" "$WORK/jniLibs/$abi/"
  ls -l "$WORK/jniLibs/$abi" > "$WORK/report/$abi-sizes.txt"
  echo "$CONFIG_ID" > "$WORK/report/$abi-config.txt"

  if [[ "$KEEP_BUILD_TREES" != 1 ]]; then
    rm -rf "$build_dir" "$VLC/contrib/contrib-android-$triplet" "$contrib" "$JNI/libvlc/jni/obj/local/$abi" "$libs"
  fi
}

if [[ "$PACKAGE_ONLY" != 1 ]]; then
  : "${ANDROID_NDK:?set ANDROID_NDK to an NDK r27 or r28 (e.g. android-ndk-r28c)}"
  rel="$(sed -n 's/^Pkg.Revision *= *\([0-9]*\)\..*/\1/p' "$ANDROID_NDK/source.properties" 2>/dev/null || true)"
  [[ "$rel" == 27 || "$rel" == 28 ]] || die "ANDROID_NDK must be r27 or r28 (libvlcjni's compile-libvlc.sh); got '${rel:-none}' at $ANDROID_NDK"
  for abi in $ABIS; do build_abi "$abi"; done
fi

# 5. The AAR: libvlcjni's Java classes and resources (libvlc/src, libvlc/res), the staged
#    libraries and the HRTF used by the spatialaudio module, built as an Android library with the
#    app's own Gradle and AGP. No Lua scripts: the lua module is GPL and not built.
staged="$(cd "$WORK/jniLibs" && { ls -d */ 2>/dev/null || true; } | tr -d / | tr '\n' ' ')"
[[ -n "$staged" ]] || die "no ABI staged in $WORK/jniLibs"
AGP="$(sed -n 's/^agp = "\(.*\)"$/\1/p' "$ANDROID_APP/gradle/libs.versions.toml")"
[[ -n "$AGP" ]] || die "could not read the AGP version from gradle/libs.versions.toml"
P="$WORK/aar"
mkdir -p "$P/libvlc/src/main/assets" "$P/libvlc/src/main"
rm -rf "$P/libvlc/src/main/assets/hrtfs"
cp -R "$VLC/share/hrtfs" "$P/libvlc/src/main/assets/hrtfs"
printf '<?xml version="1.0" encoding="utf-8"?>\n<manifest xmlns:android="http://schemas.android.com/apk/res/android" />\n' > "$P/libvlc/src/main/AndroidManifest.xml"
echo "sdk.dir=$SDK" > "$P/local.properties"
cat > "$P/settings.gradle.kts" <<EOF
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "libvlc-lgpl"
include(":libvlc")
EOF
printf 'plugins { id("com.android.library") version "%s" apply false }\n' "$AGP" > "$P/build.gradle.kts"
printf 'android.useAndroidX=true\norg.gradle.jvmargs=-Xmx2g\n' > "$P/gradle.properties"
cat > "$P/libvlc/build.gradle.kts" <<EOF
plugins { id("com.android.library") }
android {
    namespace = "org.videolan"
    compileSdk = 36
    defaultConfig {
        minSdk = 21
        resValue("string", "build_libvlc_revision", "${LIBVLCJNI_HASH:0:9}")
        resValue("string", "build_vlc_revision", "${VLC_HASH:0:9}")
    }
    sourceSets {
        getByName("main") {
            java.directories.add("$JNI/libvlc/src")
            res.directories.add("$JNI/libvlc/res")
            jniLibs.directories.add("$WORK/jniLibs")
        }
    }
    buildFeatures { resValues = true; buildConfig = true }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging { jniLibs { keepDebugSymbols += "**/*.so" } }
}
// A file AAR carries no POM: these are compile-time only, and the app's release classpath already
// has all four (VideoLAN's POM names androidx.annotation and legacy-support-v4 instead).
dependencies {
    compileOnly("androidx.annotation:annotation:1.9.1")
    compileOnly("androidx.collection:collection:1.5.0")
    compileOnly("androidx.core:core:1.17.0")
    compileOnly("androidx.lifecycle:lifecycle-livedata-core:2.10.0")
}
EOF
log "packaging the AAR ($staged)"
"$ANDROID_APP/gradlew" -q -p "$P" :libvlc:assembleRelease > "$WORK/report/aar-build.log" 2>&1 \
  || { tail -30 "$WORK/report/aar-build.log" >&2; die "AAR build failed; see $WORK/report/aar-build.log"; }
AAR="$P/libvlc/build/outputs/aar/libvlc-release.aar"
[[ -f "$AAR" ]] || die "no AAR at $AAR"
mkdir -p "$(dirname "$OUT")"
ANDROID_HOME="$SDK" "$ROOT/scripts/audit-android-libvlc.sh" "$AAR" | tee "$WORK/report/aar-audit.txt"
cp "$AAR" "$OUT"
unzip -l "$OUT" | grep -E 'jni/|classes.jar' > "$WORK/report/aar-contents.txt"
log "LGPL libVLC ready at $OUT ($staged); reports in $WORK/report"
