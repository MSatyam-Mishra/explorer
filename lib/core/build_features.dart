/// Whether this build includes the video downloader. Release builds can
/// leave it out (`--dart-define=VIDEO_DOWNLOADER=false` together with the
/// Gradle property `-Pexplorer.videoDownloader=false`, see
/// tool/build_release.py): it bundles GPL-3.0 components and adds ~4 MB
/// (its ~50 MB engine is downloaded on first use).
const bool kVideoDownloaderEnabled = bool.fromEnvironment(
  'VIDEO_DOWNLOADER',
  defaultValue: true,
);
