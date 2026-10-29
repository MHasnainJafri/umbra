# Umbra: libVLC build scripts, configuration and patches

Umbra (a video player with a private vault for Mac, iPhone, iPad and Android) ships libVLC, the
VideoLAN media library, as its fallback playback engine, under the **GNU Lesser General Public
License 2.1 or later** (LICENSE). This repository holds exactly what Umbra uses to build that
libVLC, so that you can rebuild it, change it and use your own build instead.

Umbra's own code is not open source; only the files here are published.

## What Umbra ships

| Platform | Library | Upstream sources |
|---|---|---|
| Mac | VLCKit 3.6.0 (libVLC 3.0.21, commit dd8bfdba) as a dynamic `VLCKit.framework` in `Umbra.app/Contents/Frameworks` | https://code.videolan.org/videolan/VLCKit/-/tree/3.6.0 and https://code.videolan.org/videolan/vlc/-/tree/dd8bfdba |
| iPhone, iPad | MobileVLCKit from the same sources and configuration, as a dynamic `MobileVLCKit.framework` in the app's `Frameworks` | as above |
| Android | libVLC from vlc-android `libvlc-3.6.5` (libvlcjni and VLC 3.0.x), as `libvlc.so` and `libvlcjni.so` in the APK | https://code.videolan.org/videolan/vlc-android/-/tree/libvlc-3.6.5 |

Every build is configured without GPL parts: no `--enable-gpl`/`--enable-nonfree` FFmpeg, no
GPL-only contribs or VLC modules. FFmpeg's software decoders for codecs whose patent pools still
license are left out too; the exact list is the `--disable-decoder=…` options in each script's
FFmpeg configuration step. Those formats play only through the operating system's own decoders,
where the device has one. The scripts pin the exact upstream commits.

## Files

- `scripts/build-vlckit.sh`: builds VLCKit (Mac; run on macOS with Xcode) and, with `--ios`,
  MobileVLCKit (iPhone and iPad).
- `scripts/build-libvlc-android.sh`: builds the Android libVLC (Linux with GNU sed, Android NDK r27
  or r28, Android SDK). Step 5 packages the AAR with the Gradle wrapper under `App/UmbraAndroid/`
  and reads the Android Gradle Plugin version from `App/UmbraAndroid/gradle/libs.versions.toml`.
- Patches Umbra applies to libVLC (the scripts apply them; everything else is configuration):
  - scripts/vlc-patches/0001-darwin-never-proxy-loopback.patch
  - scripts/vlc-patches/0002-deinterlace-without-yadif.patch
  - scripts/vlc-patches-android/0001-android-never-proxy-loopback.patch
  - scripts/vlc-patches-android/0002-deinterlace-without-yadif.patch
- Licence audits the builds run: `scripts/audit-libvlc-sources.py` (licence header of every source
  file compiled into libVLC), `scripts/audit-gpl-symbols.sh` (Apple frameworks and apps) and
  `scripts/audit-android-libvlc.sh` (Android libraries, APK, AAB and AAR).
- `LICENSE`, `LICENSES/LGPL-2.1.txt`: the GNU LGPL 2.1. The patches modify libVLC and are
  under the same licence as libVLC; the scripts here are published under the LGPL 2.1 or later too.
- `EXPORTED_FROM.txt` and `SHA256SUMS`: the Umbra source commit these files were exported from,
  and their checksums.

## Using your own libVLC

- **Mac:** build with `scripts/build-vlckit.sh`, replace
  `Umbra.app/Contents/Frameworks/VLCKit.framework` with your build and sign the app again with your
  own identity (for local use, for example
  `codesign --force --deep --preserve-metadata=entitlements --sign - Umbra.app`).
- **iPhone and iPad:** build with `scripts/build-vlckit.sh --ios`, replace
  `Frameworks/MobileVLCKit.framework` inside the app and sign it again for your own device with your
  own Apple developer identity.
- **Android:** build with `scripts/build-libvlc-android.sh`, replace `lib/<abi>/libvlc.so` and
  `libvlcjni.so` in the APK with yours, then align and sign the APK with your own key (`zipalign`,
  `apksigner`) and install it. An app signed with a different key cannot update or read the data of
  the store version.

Questions: see https://mhasnainjafri.github.io/umbra/ for contact details.
