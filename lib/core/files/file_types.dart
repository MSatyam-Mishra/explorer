import 'package:path/path.dart' as p;

/// Every kind of file the explorer knows how to handle in-app.
///
/// [FileTypes.kindOf] maps a path to one of these; the router, icons and
/// "open with" sheet all key off this single registry.
enum FileKind {
  image,
  rasterImage,
  svg,
  video,
  audio,
  pdf,
  epub,
  ebook,
  comic,
  word,
  legacyWord,
  richText,
  openDocumentText,
  spreadsheet,
  legacySpreadsheet,
  delimited,
  openDocumentSpreadsheet,
  presentation,
  legacyPresentation,
  openDocumentPresentation,
  model3d,
  archive,
  diskImage,
  cameraRaw,
  design,
  markdown,
  html,
  json,
  lottie,
  rive,
  font,
  code,
  text,
  package,
  unknown,
}

abstract final class FileTypes {
  /// Images Flutter's engine decodes natively.
  static const image = {
    'jpg', 'jpeg', 'jfif', 'pjpeg', 'png', 'apng', 'gif', 'webp', 'bmp',
    'wbmp', 'ico', 'heic', 'heif', 'avif',
  };

  /// Images decoded in Dart by the `image` package and shown as PNG.
  static const rasterImage = {
    'tif', 'tiff', 'tga', 'psd', 'exr', 'pnm', 'ppm', 'pgm', 'pbm', 'pam',
    'pvr', 'cur',
  };

  static const svg = {'svg', 'svgz'};

  static const video = {
    'mp4', 'm4v', 'mkv', 'webm', 'avi', 'mov', 'qt', '3gp', '3g2',
    'mts', 'm2ts', 'flv', 'wmv', 'mpg', 'mpeg', 'ogv', 'vob', 'divx',
  };

  static const audio = {
    'mp3', 'wav', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'm4b', 'aac', 'wma',
    'amr', 'aiff', 'aif', 'mka', 'caf', 'weba',
  };

  static const pdf = {'pdf'};
  static const epub = {'epub'};
  static const ebook = {'fb2', 'fbz', 'mobi', 'azw', 'azw3', 'prc'};
  static const comic = {'cbz', 'cbr', 'cb7', 'cbt'};

  static const word = {'docx', 'docm', 'dotx', 'dotm'};
  static const legacyWord = {'doc', 'dot', 'wps'};
  static const richText = {'rtf'};
  static const openDocumentText = {'odt', 'ott', 'fodt'};

  static const spreadsheet = {'xlsx', 'xlsm', 'xltx', 'xltm'};
  static const legacySpreadsheet = {'xls', 'xlt'};
  static const delimited = {'csv', 'tsv', 'tab', 'psv'};
  static const openDocumentSpreadsheet = {'ods', 'ots'};

  static const presentation = {'pptx', 'pptm', 'ppsx', 'potx', 'ppsm'};
  static const legacyPresentation = {'ppt', 'pps', 'pot'};
  static const openDocumentPresentation = {'odp', 'otp'};

  static const model3d = {
    'glb', 'gltf', 'obj', 'stl', 'ply', 'fbx', 'dae', '3ds', '3mf', 'amf',
    'wrl', 'vrml', 'usdz', 'usda', 'usdc', 'off', 'xyz', 'pcd', 'vtk',
    'vtp', 'lwo', 'md2', 'vox', 'gcode', 'drc', 'kmz', '3dm', 'blend',
    'blend1',
  };

  static const archive = {
    'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'tbz', 'tbz2', 'xz',
    'txz', 'jar', 'war', 'aar', 'xapk', 'apks',
  };

  static const diskImage = {'iso'};

  /// Camera raw formats; viewers show the JPEG preview the camera embeds.
  static const cameraRaw = {
    'dng', 'cr2', 'cr3', 'crw', 'nef', 'nrw', 'arw', 'srf', 'sr2', 'orf',
    'rw2', 'raf', 'pef', 'srw', '3fr', 'iiq', 'erf', 'mef', 'mos', 'dcr',
    'kdc', 'x3f', 'rwl', 'raw',
  };

  /// Design, CAD and print files shown through their embedded preview.
  static const design = {
    'ai', 'eps', 'epsf', 'epsi', 'ps', 'indd', 'indt', 'fig', 'dwg',
    'sketch', 'kra', 'ora', 'procreate', 'cdr', 'xd', 'afdesign', 'afphoto',
    'afpub', 'pages', 'numbers',
  };

  static const markdown = {'md', 'markdown', 'mdown', 'mkd', 'mdx'};
  static const html = {'html', 'htm', 'xhtml', 'shtml'};
  static const json = {'json', 'geojson', 'jsonc', 'json5', 'har'};
  static const lottie = {'lottie'};
  static const rive = {'riv'};
  static const font = {'ttf', 'otf'};
  static const package = {'apk', 'exe', 'msi', 'dmg', 'deb', 'rpm', 'appx'};

  /// Installer files macOS opens in Installer. Elsewhere a .pkg is often
  /// something else (a game package), so they stay unknown in [kindOf].
  static const macInstaller = {'pkg', 'mpkg'};

  /// Folders macOS shows and opens as one item, as Finder does: apps,
  /// plug-ins and document packages. Frameworks and .lproj folders are
  /// ordinary folders there.
  static const macPackage = {
    // Apps, extensions and plug-ins
    'app', 'appex', 'bundle', 'plugin', 'kext', 'prefpane', 'qlgenerator',
    'mdimporter', 'saver', 'wdgt', 'xpc', 'component', 'scptd', 'workflow',
    'action',
    // Documents and libraries
    'rtfd', 'pages', 'numbers', 'key', 'photoslibrary', 'photolibrary',
    'musiclibrary', 'imovielibrary', 'theater', 'fcpbundle', 'logicx', 'band',
    'xcarchive', 'xcodeproj', 'xcworkspace', 'playground', 'docset',
    'mlpackage', 'sparsebundle', 'download',
    // Installers kept as folders (older .pkg and .mpkg)
    'pkg', 'mpkg',
  };

  /// Whether a folder at [path] is a macOS package, going by its name.
  /// Callers check that they are on macOS.
  static bool isMacPackage(String path) => macPackage.contains(extensionOf(path));

  static const code = {
    // Web
    'js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx', 'css', 'scss', 'sass', 'less',
    'vue', 'svelte', 'astro', 'php',
    // Systems & app languages
    'c', 'h', 'cc', 'cpp', 'cxx', 'hpp', 'hh', 'hxx', 'm', 'mm', 'cs',
    'java', 'kt', 'kts', 'scala', 'groovy', 'gradle', 'swift', 'go', 'rs',
    'dart', 'zig', 'nim', 'v', 'd',
    // Scripting
    'py', 'pyw', 'pyi', 'rb', 'pl', 'pm', 'lua', 'r', 'jl', 'ex', 'exs',
    'erl', 'hrl', 'clj', 'cljs', 'edn', 'hs', 'elm', 'fs', 'fsx', 'ml',
    'mli', 'ps1', 'psm1', 'sh', 'bash', 'zsh', 'fish', 'bat', 'cmd', 'vbs',
    'awk', 'tcl', 'coffee',
    // Data & config
    'xml', 'xsd', 'xsl', 'xslt', 'plist', 'opml', 'rss', 'atom', 'kml',
    'gpx', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'config', 'env',
    'properties', 'prop', 'sql', 'graphql', 'gql', 'proto', 'tf', 'hcl',
    'cmake', 'make', 'mk', 'mak', 'dockerfile', 'nix', 'lock', 'pbxproj',
    'xaml', 'csproj', 'sln', 'vcxproj', 'arb', 'tex', 'bib',
    'sty', 'cls', 'ipynb', 'reg', 'desktop', 'service', 'editorconfig',
    'gitignore', 'gitattributes', 'npmrc', 'babelrc', 'eslintrc',
    'prettierrc', 'htaccess', 'diff', 'patch',
  };

  static const text = {
    'txt', 'text', 'log', 'out', 'nfo', 'rst', 'adoc', 'asciidoc', 'org',
    'srt', 'vtt', 'ass', 'ssa', 'sub', 'lrc', 'vcf', 'vcard', 'ics', 'eml',
    'csr', 'pem', 'crt', 'key', 'pub', 'asc', 'readme', 'license', 'me',
    '1st', 'now', 'todo', 'cue', 'm3u', 'm3u8', 'pls', 'url', 'diz',
  };

  /// Extension-less names that are almost always text.
  static const textFileNames = {
    'readme', 'license', 'licence', 'copying', 'authors', 'changelog',
    'makefile', 'dockerfile', 'gemfile', 'rakefile', 'procfile', 'vagrantfile',
    'jenkinsfile', 'podfile', 'brewfile', 'cmakelists.txt', 'notice',
    '.gitignore', '.gitattributes', '.editorconfig', '.env', '.npmrc',
    '.bashrc', '.zshrc', '.profile',
  };

  static final Map<String, FileKind> _byExtension = {
    for (final e in image) e: FileKind.image,
    for (final e in rasterImage) e: FileKind.rasterImage,
    for (final e in svg) e: FileKind.svg,
    for (final e in video) e: FileKind.video,
    for (final e in audio) e: FileKind.audio,
    for (final e in pdf) e: FileKind.pdf,
    for (final e in epub) e: FileKind.epub,
    for (final e in ebook) e: FileKind.ebook,
    for (final e in comic) e: FileKind.comic,
    for (final e in word) e: FileKind.word,
    for (final e in legacyWord) e: FileKind.legacyWord,
    for (final e in richText) e: FileKind.richText,
    for (final e in openDocumentText) e: FileKind.openDocumentText,
    for (final e in spreadsheet) e: FileKind.spreadsheet,
    for (final e in legacySpreadsheet) e: FileKind.legacySpreadsheet,
    for (final e in delimited) e: FileKind.delimited,
    for (final e in openDocumentSpreadsheet) e: FileKind.openDocumentSpreadsheet,
    for (final e in presentation) e: FileKind.presentation,
    for (final e in legacyPresentation) e: FileKind.legacyPresentation,
    for (final e in openDocumentPresentation)
      e: FileKind.openDocumentPresentation,
    for (final e in model3d) e: FileKind.model3d,
    for (final e in archive) e: FileKind.archive,
    for (final e in diskImage) e: FileKind.diskImage,
    for (final e in cameraRaw) e: FileKind.cameraRaw,
    for (final e in design) e: FileKind.design,
    for (final e in text) e: FileKind.text,
    for (final e in code) e: FileKind.code,
    for (final e in markdown) e: FileKind.markdown,
    for (final e in html) e: FileKind.html,
    for (final e in json) e: FileKind.json,
    for (final e in lottie) e: FileKind.lottie,
    for (final e in rive) e: FileKind.rive,
    for (final e in font) e: FileKind.font,
    for (final e in package) e: FileKind.package,
  };

  /// Lower-case extension without the dot (`report.PDF` → `pdf`).
  static String extensionOf(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext.startsWith('.') ? ext.substring(1) : ext;
  }

  /// Later parts of multi-volume archives: `.r00`, `.s01`, `.7z.001`, ….
  static final _volumePart = RegExp(r'^(?:[rs]\d\d|\d{3})$');

  static FileKind kindOf(String path) {
    if (path.toLowerCase().endsWith('.fb2.zip')) return FileKind.ebook;
    final ext = extensionOf(path);
    if (_volumePart.hasMatch(ext)) return FileKind.archive;
    if (ext.isEmpty) {
      final name = p.basename(path).toLowerCase();
      return textFileNames.contains(name) ? FileKind.text : FileKind.unknown;
    }
    final kind = _byExtension[ext];
    if (kind != null) return kind;
    // Dotfiles such as `.gitignore` have the whole name as "extension".
    if (textFileNames.contains(p.basename(path).toLowerCase())) {
      return FileKind.text;
    }
    return FileKind.unknown;
  }

  static bool isTextual(FileKind kind) => const {
        FileKind.code,
        FileKind.text,
        FileKind.markdown,
        FileKind.html,
        FileKind.json,
        FileKind.delimited,
        FileKind.svg,
      }.contains(kind);

  /// Human readable name for "Open with" and info sheets.
  static String describe(FileKind kind) => switch (kind) {
        FileKind.image || FileKind.rasterImage => 'Image',
        FileKind.svg => 'Vector image',
        FileKind.video => 'Video',
        FileKind.audio => 'Audio',
        FileKind.pdf => 'PDF document',
        FileKind.epub || FileKind.ebook => 'E-book',
        FileKind.comic => 'Comic book',
        FileKind.word ||
        FileKind.legacyWord ||
        FileKind.richText ||
        FileKind.openDocumentText =>
          'Document',
        FileKind.spreadsheet ||
        FileKind.legacySpreadsheet ||
        FileKind.delimited ||
        FileKind.openDocumentSpreadsheet =>
          'Spreadsheet',
        FileKind.presentation ||
        FileKind.legacyPresentation ||
        FileKind.openDocumentPresentation =>
          'Presentation',
        FileKind.model3d => '3D model',
        FileKind.archive => 'Archive',
        FileKind.diskImage => 'Disk image',
        FileKind.cameraRaw => 'Camera raw photo',
        FileKind.design => 'Design file',
        FileKind.markdown => 'Markdown',
        FileKind.html => 'Web page',
        FileKind.json => 'JSON',
        FileKind.lottie => 'Lottie animation',
        FileKind.rive => 'Rive animation',
        FileKind.font => 'Font',
        FileKind.code => 'Source code',
        FileKind.text => 'Text',
        FileKind.package => 'Installer package',
        FileKind.unknown => 'File',
      };

  static const _mimeByExtension = {
    'html': 'text/html', 'htm': 'text/html', 'xhtml': 'application/xhtml+xml',
    'xml': 'application/xml', 'css': 'text/css', 'js': 'text/javascript',
    'mjs': 'text/javascript', 'json': 'application/json', 'txt': 'text/plain',
    'svg': 'image/svg+xml', 'png': 'image/png', 'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg', 'gif': 'image/gif', 'webp': 'image/webp',
    'bmp': 'image/bmp', 'ico': 'image/x-icon', 'avif': 'image/avif',
    'tif': 'image/tiff', 'tiff': 'image/tiff', 'ttf': 'font/ttf',
    'otf': 'font/otf', 'woff': 'font/woff', 'woff2': 'font/woff2',
    'wasm': 'application/wasm', 'mp3': 'audio/mpeg', 'mp4': 'video/mp4',
    'webm': 'video/webm', 'ogg': 'audio/ogg', 'wav': 'audio/wav',
    'm4a': 'audio/mp4', 'pdf': 'application/pdf',
    'glb': 'model/gltf-binary', 'gltf': 'model/gltf+json',
    'ncx': 'application/x-dtbncx+xml', 'opf': 'application/oebps-package+xml',
  };

  static String mimeTypeOf(String path) =>
      _mimeByExtension[extensionOf(path)] ?? 'application/octet-stream';
}
