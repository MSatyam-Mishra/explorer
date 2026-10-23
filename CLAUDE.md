# Explorer: notes for Claude Code

Flutter app "Explorer" (`com.synqixlabs.explory`), a universal file manager with
built-in viewers and tools, for **Android, Windows and Linux** (macOS builds too; see below). Repo:
`MSatyam-Mishra/explorer` (public). Owner: Satyam (MSatyam-Mishra).

## Working with the owner

- **Never add Claude as co-author or contributor**: no `Co-Authored-By` lines in commits, PRs, tags or release notes (`.claude/settings.json` turns attribution off; keep it that way).
- He prefers action over discussion and short status updates. Run long jobs (builds, CI waits) in the background and say what's happening. He gets impatient with long silences.
- Commit style: an imperative summary line, then plain-language paragraphs on what changed for users (see `git log`). Commit per finished feature and push to `main`.
- Never print secrets (git credential token, `android/key.properties`, MSIX password).

## Toolchain and commands

- Flutter 3.44.1 stable, Dart 3.12. Android SDK (AVD `explorer_test`, Play Store image, x86_64). Rust is installed on the main PC; `super_drag_and_drop` (cargokit) uses precompiled binaries.
- macOS (a MacBook, Xcode 26, CocoaPods, rustup): `flutter build macos --release` gives `build/macos/Build/Products/Release/Explorer.app` (universal, macOS 12+, sandbox off). `super_native_extensions` compiles Rust through a native-assets hook (toolchain 1.97.1), so rustup must be installed. The app is ad-hoc signed (no Developer ID), so other Macs show a Gatekeeper warning; a DMG is made with `hdiutil create -srcfolder`.
- `flutter analyze lib test`: the only known findings are old ones in `lib/core/services/driver/mass_storage_driver.dart`, `lib/core/services/usb_host_service.dart` and `plugins/vocsy_epub_viewer-main`.
- `flutter test`: about 160 tests, about 30 s. Screenshots: `SCREENSHOTS=1 flutter test test/screenshots` writes `build/screenshots/*.png`. On a device: `flutter test integration_test/image_text_test.dart -d <device>`.
- Widget tests run on a fake clock, so real file I/O must go inside `tester.runAsync` (the `settle()` helpers alternate `runAsync` and `pump`). Under `FLUTTER_TEST` the app uses an in-memory clipboard, no folder watching, no native drag and drop and no OCR in the viewer. Opt-in: `EXPLORER_REAL_CLIPBOARD=1` (real Windows clipboard test), `EXPLORER_FFMPEG=path` (converter tests).
- Long Python edit scripts: write them to a file and run with `python -I -X utf8 script.py` (bash heredocs with quotes break). Don't run `dart format` on whole files that aren't already formatted.

## Map

- `lib/main.dart`: startup. `BackgroundMode.instance.init()` runs on desktop; `MaterialApp.builder` shows only `TasksView` while in tasks mode, with the app kept alive behind it.
- `lib/features/file_explorere/` (the folder name's typo is real; keep it):
  - `screens/file_explorer_screen.dart`: the browser. It handles clicks, keys (Ctrl+C/X/V/A/N/F, F2, F5, Del, Esc), right-click menus, drag and drop, and group headings.
  - `bloc/`: the folder bloc (loading, sort, `GroupBy` groups, search, folder watching), `grouping.dart`, `folder_search.dart` (isolate search).
  - `widgets/`: `explorer_header.dart` (search box, sort/group menu, new window), `explorer_menu.dart` (popup menus with `submenu`), `file_drag_drop.dart`, `image_actions.dart` (Convert to ▸, Resize dialog).
- `lib/features/clipboard/`: the clipboard bloc shared by all windows, plus `paste_task.dart` (the copy/move engine: no overwrites, cross-drive moves, streaming).
- `lib/core/services/`:
  - `file_clipboard.dart`: the Windows CF_HDROP clipboard; Linux/macOS use a shared JSON file.
  - `file_server/`: HTTP and FTP servers; `only:` limits sharing to the chosen items.
  - `bluetooth_share.dart`.
  - `image_text.dart`: OCR. Windows uses `Windows.Media.Ocr` through Windows PowerShell 5.1; Android uses ML Kit through Play services (`ImageTextNative.kt`); Linux uses the bundled or system Tesseract.
  - `image_convert/`: `image_formats.dart`, `image_converter.dart` and `heif_writer.dart` (wraps libx265 HEVC from FFmpeg into .heic; checked with libheif). The converter uses Dart `image` for PNG/JPEG/GIF/BMP/TIFF/ICO/TGA/SVG, FFmpeg for WebP/AVIF/HEIC on desktop, and native encoders on Android.
  - `background_tasks.dart`: tasks shown in the progress dock and the Tasks view (copies, conversions, FFmpeg download).
  - `video_downloader/`: yt-dlp. The Android engine is downloaded on first use from the `video-engine-0.18.1` release; desktop FFmpeg/Deno go to `<appSupport>/video_downloader`.
- `lib/core/platform/`: `desktop.dart` (new windows via `Desktop.openWindow`, `launcher` hook for tests), `background_mode.dart` (close while busy: Windows hides to the tray, Linux shrinks to a Tasks window) and `window_effects.dart` (the translucent window through `flutter_acrylic`: Acrylic on Windows, vibrancy on macOS, a transparent window on Linux). With the setting on, `AppTheme.shad` makes `background` translucent, and dialogs, sheets, the drawer and the canvas stay solid. The setting is a switch in the options sheet, saved as `window_effect`.
- `linux/runner/my_application.cc`: the window is shown by `flutter_acrylic` (`Window.initialize()` in `main`), not by the runner. It also sets `_KDE_NET_WM_BLUR_BEHIND_REGION` so KDE on X11 blurs behind the window.
- `lib/shared/ui/app_sheet.dart`: `AppSheet.show(style:)` gives a bottom sheet on phones, and on computers and wide screens a dialog (`SheetStyle.dialog`, for choices) or a side sheet (`SheetStyle.side`, for details and settings). `AppSheet.showRaw` is for content that scrolls itself. The owner wants no bottom sheets on desktop, and icons on every menu and option item.
- `lib/shared/widgets/`: `progress_dock.dart` (bottom-right tasks, hide to a ring), `tasks_view.dart`, `round_qr_code.dart`.
- Android native code is in `android/app/src/main/kotlin/com/example/explorer/` (`MainActivity` registers `*Native` classes per channel). The video downloader flavour lives in `src/videoDownloader/`.
- `windows/runner/`: `main.cpp` (a new window cascades from the one that opened it) and `flutter_window.cpp` (tray icon, channel `explorer/tray`: show/hide/notify; it sends clicked/open/quit).

## Releases

GitHub **pre-releases** tagged `vX.Y.Z`:

1. Bump `version:` in `pubspec.yaml` (versionCode +1), commit "Release vX.Y.Z: …", run `python tool/build_release.py`. It writes `build/release/vX.Y.Z/`: 4 APKs and `SHA256SUMS.txt`.
2. **APK signing needs `android/key.properties` and the keystore, which exist only on the main dev PC** (cert SHA-256 starts `86:57:22:49`). Other machines can't build installable updates unless the keystore is copied over securely. Check with `apksigner verify --print-certs`.
3. Tag (annotated), then push `main` and the tag.
4. Run `python tool/release/publish_release.py OWNER/REPO TAG TITLE NOTES.md files…`, which creates the release and uploads, then `tool/release/verify_release.py` to check the uploads. Write notes for app users (what's new, which APK, Windows and Linux install tables; see the v1.0.7 release).
5. Publishing triggers `.github/workflows/desktop-release.yml`, which builds, install-checks and attaches the Windows packages (setup .exe, .msix, .msixbundle, .cer) and Linux packages (deb, rpm, AppImage, flatpak, snap, tar.gz/xz). It can also be run by hand: `python tool/release/actions.py dispatch MSatyam-Mishra/explorer desktop-release.yml main tag=vX ref=vX upload=true`. If some jobs passed and others failed, `tool/release/upload_desktop.py OWNER/REPO RUN_ID TAG WORKDIR` attaches what was built. No Windows zip (the owner doesn't want one).
6. Known CI flakiness: the Ubuntu apt mirror can stall. apt now retries with a 30 s timeout, and the package check job is capped at 30 min. The Linux portable bundle carries libmpv and Tesseract (`packaging/linux/system-libs.txt` lists what's left to the system).

## Where things stand (2026-10-23)

- **v1.0.7** is complete.
- **v1.0.8** (convert and resize, background tasks and tray, translucent window, side sheets and dialogs, menu icons) is published with its APKs. Its Windows and Linux packages come from the `release` run of desktop-release.yml started on 2026-10-23. Check that the release has 16 files; if a job failed, re-run it (Releases, step 5) or attach what was built with `tool/release/upload_desktop.py`.
- The repo sidebar listed "claude" as a contributor long after the co-author lines were removed from history (a stale cache). Switching the default branch to a temporary branch and back made GitHub recompute it; it now shows only the owner.
- **In progress, committed but not finished: image conversion, resize and background mode.**
  - Done and tested: the converter (all formats; HEIC validated with libheif; WebP/AVIF keep transparency), the Convert to ▸ and Resize… menus (right-click, selection, phone sheet, selection bar), background tasks in the dock, the widget test for convert and resize, and copies registered as background tasks.
  - Still to do:
    1. Try the Windows tray by hand: close while a conversion runs, check it hides to the tray, click to open the Tasks view, then Open Explorer and Quit.
    2. The Linux Tasks window (shrinks, closes itself when done) is untested. `window_manager` was added, so check that CI's Linux build passes.
    3. Run the Android `ImageConvertNative` (HeifWriter 1.1.0, ImageDecoder) on the emulator: JPG→WebP/HEIC, HEIC→PNG, resize.
    4. Review screenshots of the Resize dialog and the Tasks view.
    5. Next release (v1.0.8): README and release notes.
- **Translucent window (Acrylic)**: done and checked on Windows 11 (a colourful window behind shows through, blurred). Linux (transparent, blur only on KDE/X11 or compositors that force it) and macOS (vibrancy) are untested: check that the Linux window still appears in CI's start check and on a real desktop. One unexplained `flutter_windows.dll` crash happened once while testing with two windows open; it didn't come back in later tries, so watch for it.
- **macOS** (2026-10-24): builds and starts. A code check found Mac gaps still to fix: Cmd+Q skips close-while-busy (copies cut short), copies drop file permissions, `.app` opens as a folder, folder share deletes its zip too soon, no OCR (could use Vision), no FFmpeg download for macOS (WebP/AVIF/HEIC, video merging), Audio category empty, Finder clipboard, Delete key and Control-click, Cmd+F in the editor, new volumes not shown, Finder "Open With" ignored. Not in CI yet.
- Ideas not started: keeping conversions alive on Android after the app is closed (foreground service); Recycle Bin/Trash; back/forward history; mouse-wheel zoom in the image viewer; known folders/OneDrive; multi-select in the archive viewer.
