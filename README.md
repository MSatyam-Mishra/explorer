# Explorer

A file manager for Android (also Windows, macOS and Linux) that opens almost any file inside the app. It can send files to nearby devices with [LocalSend](https://github.com/localsend/localsend) and download videos with [yt-dlp](https://github.com/yt-dlp/yt-dlp), like [VidBee](https://github.com/nexmoe/VidBee).

Download the latest APK from [Releases](https://github.com/MSatyam-Mishra/explorer/releases). Most phones need the `arm64-v8a` APK; use `armeabi-v7a` for older 32-bit phones, `x86_64` for emulators and Chromebooks, or `universal` if unsure. Android 7.0 or newer.

## Features

- **Documents**:
  - PDF: view, annotate, fill forms, edit pages, passwords.
  - Word (DOCX, DOC, RTF, ODT): page view and editing.
  - Spreadsheets (XLSX, XLS, ODS, CSV): formulas and editing.
  - Presentations (PPTX, PPT, ODP): slideshow and text editing.
- **Reading**: EPUB, FB2 and MOBI/AZW3 e-books; CBZ, CBR, CB7 and CBT comics.
- **Archives**: ZIP, RAR (v4 and v5), 7z, TAR (gz, bz2, xz) and ISO. Browse, open files inside, extract, and handle passwords and multi-part archives.
- **Images**:
  - common formats plus TIFF, PSD and camera RAW previews;
  - an image editor and EXIF details;
  - previews of design and CAD files (AI, EPS, DWG, Sketch, Figma, Krita and more).
- **Media and more**: video and audio, 3D models (glTF, OBJ, STL, FBX and others), fonts, web pages, Markdown, a code editor with syntax colours, and a hex viewer for everything else.
- **Nearby sharing** with LocalSend, and a **video downloader** (both below).
- **Share in a browser**: **Options → HTTP file server** turns the current folder into a web page for any device on the same Wi-Fi. It has search, list and grid views, photo and video previews, ZIP downloads of whole folders, and uploads (off unless you allow them).
- **System integration**: Explorer appears in Android's "Open with" and "Share" menus, with tablet and foldable layouts and three file-icon styles.

## Nearby sharing (LocalSend)

Explorer speaks the [LocalSend protocol](https://github.com/localsend/protocol), so it can exchange files with the official [LocalSend](https://github.com/localsend/localsend) app on Android, iOS, Windows, macOS and Linux, and with other copies of Explorer. No internet or account is needed; both devices only have to be on the same Wi-Fi or LAN.

- **Send**: select files or folders and tap **Send nearby**, or use **Send nearby (LocalSend)** in a file's menu. Then pick the device.
- **Receive**: open **Menu → Tools → Nearby share**. While that screen is open, other devices can find you; you accept or decline each transfer.
- **Received files** go to `Download/LocalSend`.
- **Settings**: device name, PIN, auto-accept and folder.
- **Security**: transfers use HTTPS with a certificate generated on your device, as LocalSend does.

This is an independent implementation of the protocol written from its specification. It is not affiliated with the LocalSend project.

## Video downloader (yt-dlp)

> **Not in the release APKs yet.** The downloader bundles GPL-3.0 components (youtubedl-android and FFmpeg) and adds about 54 MB per APK, so published builds are made without it (`python tool/build_release.py --without-video-downloader`). Build from source to try it.

Download videos or audio from the [many sites yt-dlp supports](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md). It is the same engine that [VidBee](https://github.com/nexmoe/VidBee) uses on the desktop.

- In a browser or video app, tap **Share → Download video**. Or open **Menu → Tools → Video downloader** and paste a link.
- Choose a quality (up to 4K where available) or audio only (M4A or MP3), or pick an exact format. Playlists are supported.
- Downloads continue in the background with a notification and are saved to `Download/Explorer Videos`.
- yt-dlp keeps itself up to date (Settings in the downloader).
- **On Android**, the first use unpacks the bundled Python, yt-dlp and FFmpeg, about 200 MB.
- **On desktop**, the official yt-dlp is downloaded on first use. Install [FFmpeg](https://ffmpeg.org/) to merge high-quality video and audio.

Only download content you have the right to download, and respect each site's terms.

## Building from source

Requires Flutter 3.44 or newer.

```sh
flutter pub get
flutter run
```

Release APKs (all ABIs plus universal, obfuscated, with SHA-256 checksums) are built into `build/release/v<version>/`. Add `--without-video-downloader` to leave the downloader out:

```sh
python tool/build_release.py
python tool/build_release.py --without-video-downloader
```

Release signing reads `android/key.properties`, which is git-ignored. Without that file, builds use the debug key.

```properties
storePassword=…
keyPassword=…
keyAlias=…
storeFile=C:/path/to/release.jks
```

After adding or renaming icons in `assets/iocns`, regenerate the icon catalog:

```sh
python tool/generate_file_icon_catalog.py
```

## Credits and third-party software

| Project | Used for | License |
|---|---|---|
| [LocalSend](https://github.com/localsend/localsend) / [protocol](https://github.com/localsend/protocol) | Nearby sharing protocol; implemented from the spec | Apache-2.0 |
| [VidBee](https://github.com/nexmoe/VidBee) | Reference for the video downloader's features | MIT |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Video download engine | Unlicense |
| [youtubedl-android](https://github.com/yausername/youtubedl-android) | yt-dlp, Python and FFmpeg on Android | GPL-3.0 |
| [FFmpeg](https://ffmpeg.org/) (bundled Android build) | Merging and converting downloads | GPL-3.0-or-later |
| [Python](https://www.python.org/) (bundled on Android) | Runs yt-dlp | PSF-2.0 |
| [koni_archive](https://github.com/zenbaku/koni_archive) | RAR and 7z decoding (patched copy in `third_party/koni_rar`) | MIT |
| [three.js](https://threejs.org/) | 3D model viewer | MIT |
| [Syncfusion Flutter PDF](https://pub.dev/packages/syncfusion_flutter_pdfviewer) | PDF viewer and editor | Syncfusion license |

The full list, with every Dart package's license, is under Licenses inside the app.
