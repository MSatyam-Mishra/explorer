/// Whether this build includes the video downloader. Release builds can
/// leave it out (`--dart-define=VIDEO_DOWNLOADER=false` together with the
/// Gradle property `-Pexplorer.videoDownloader=false`, see
/// tool/build_release.py): it bundles GPL-3.0 components and adds ~54 MB.
const bool kVideoDownloaderEnabled = bool.fromEnvironment(
  'VIDEO_DOWNLOADER',
  defaultValue: true,
);
