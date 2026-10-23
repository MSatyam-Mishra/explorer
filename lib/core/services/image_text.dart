import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A line of text found in an image, with where each word is (in the
/// pixels of [ImageText.size]).
@immutable
class TextLine {
  const TextLine(this.text, this.words);

  final String text;
  final List<(String, Rect)> words;

  Rect get box => words.map((w) => w.$2).reduce((a, b) => a.expandToInclude(b));
}

/// The text in an image, for selecting and copying it.
@immutable
class ImageText {
  const ImageText(this.size, this.lines);

  /// The image as read: upright, possibly scaled down.
  final Size size;
  final List<TextLine> lines;

  bool get isEmpty => lines.isEmpty;
  String get text => lines.map((l) => l.text).join('\n');

  /// Windows' OCR JSON (see [ImageTextReader]).
  static ImageText? fromWindowsJson(String json) => fromMap(jsonDecode(json));

  /// `{w, h, lines: [{t, words: [{t, x, y, w, h}]}]}`, from Windows' OCR or
  /// Android's ML Kit.
  static ImageText? fromMap(Object? data) {
    if (data is! Map || data['error'] != null) return null;
    List<Object?> list(Object? value) => value is List ? value : [if (value != null) value];
    double n(Object? v) => (v as num).toDouble();
    return ImageText(Size(n(data['w']), n(data['h'])), [
      for (final line in list(data['lines']).cast<Map>())
        TextLine('${line['t']}', [
          for (final w in list(line['words']).cast<Map>())
            ('${w['t']}', Rect.fromLTWH(n(w['x']), n(w['y']), n(w['w']), n(w['h']))),
        ]),
    ].where((l) => l.words.isNotEmpty).toList());
  }

  /// Tesseract's TSV output.
  static ImageText? fromTesseractTsv(String tsv) {
    Size? size;
    final lines = <String, List<(String, Rect)>>{};
    for (final row in const LineSplitter().convert(tsv).skip(1)) {
      final c = row.split('\t');
      if (c.length < 12) continue;
      final box = Rect.fromLTWH(double.parse(c[6]), double.parse(c[7]), double.parse(c[8]), double.parse(c[9]));
      if (c[0] == '1') size = box.size;
      final text = c[11].trim();
      if (c[0] != '5' || text.isEmpty) continue;
      (lines['${c[2]}.${c[3]}.${c[4]}'] ??= []).add((text, box));
    }
    if (size == null) return null;
    return ImageText(size, [
      for (final words in lines.values) TextLine(words.map((w) => w.$1).join(' '), words),
    ]);
  }
}

/// Finds the text in images on the device: Windows' own OCR
/// (Windows.Media.Ocr, as the Photos app uses), ML Kit from Google Play
/// services on Android, and Tesseract on Linux (the app's copy, else the
/// system's).
abstract final class ImageTextReader {
  static const _android = MethodChannel('explorer/image_text');

  static final _cache = <String, ImageText?>{};
  static String? _tesseract;
  static bool _lookedForTesseract = false;

  /// Whether the viewer looks for text (not in widget tests, which can't
  /// run the system's tools).
  static bool get enabled => supported && !Platform.environment.containsKey('FLUTTER_TEST');

  static bool get supported {
    if (Platform.isWindows || Platform.isAndroid) return true;
    if (Platform.isLinux) return _tesseractPath != null;
    return false;
  }

  /// The portable Linux packages carry Tesseract and its English data in
  /// tesseract/ next to the app.
  static String get _bundledTesseract =>
      p.join(p.dirname(Platform.resolvedExecutable), 'tesseract');

  static String? get _tesseractPath {
    if (_lookedForTesseract) return _tesseract;
    _lookedForTesseract = true;
    final bundled = p.join(_bundledTesseract, 'tesseract');
    if (File(bundled).existsSync()) return _tesseract = bundled;
    for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
      if (dir.isNotEmpty && File(p.join(dir, 'tesseract')).existsSync()) {
        return _tesseract = p.join(dir, 'tesseract');
      }
    }
    return null;
  }

  /// The text in [file]; null when there's none or it can't be read.
  static Future<ImageText?> read(File file) async {
    if (!supported) return null;
    FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      return null;
    }
    final key = '${file.path}|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
    if (_cache.containsKey(key)) return _cache[key];
    ImageText? text;
    try {
      text = Platform.isWindows
          ? await _windows(file.path)
          : Platform.isAndroid
              ? ImageText.fromMap(await _android.invokeMethod<Object?>('read', {'path': file.path}))
              : await _linux(file.path);
    } catch (_) {
      text = null;
    }
    if (_cache.length > 40) _cache.remove(_cache.keys.first);
    return _cache[key] = (text == null || text.isEmpty) ? null : text;
  }

  static Future<ImageText?> _windows(String path) async {
    final script = File(p.join(Directory.systemTemp.path, 'explorer_ocr_1.ps1'));
    if (!await script.exists()) await script.writeAsString(_windowsScript);
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = await Process.run(
      p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      // Windows' file API wants a full path.
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path, p.normalize(p.absolute(path))],
      stdoutEncoding: utf8,
    ).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) return null;
    // Windows PowerShell starts UTF-8 output with a byte order mark.
    final out = (result.stdout as String).replaceFirst('\uFEFF', '').trim();
    return out.isEmpty ? null : ImageText.fromWindowsJson(out);
  }

  static Future<ImageText?> _linux(String path) async {
    final tesseract = _tesseractPath!;
    final bundled = p.isWithin(_bundledTesseract, tesseract);
    final result = await Process.run(
      tesseract,
      [path, 'stdout', 'tsv'],
      environment: {if (bundled) 'TESSDATA_PREFIX': p.join(_bundledTesseract, 'tessdata')},
      stdoutEncoding: utf8,
    ).timeout(const Duration(seconds: 60));
    return result.exitCode == 0 ? ImageText.fromTesseractTsv(result.stdout as String) : null;
  }

  /// Runs in Windows PowerShell 5.1, which can call WinRT.
  static const _windowsScript = r'''
param([string]$Path)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($operation, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation))
  $task.Wait() | Out-Null
  $task.Result
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { '{"error":"no-language"}'; exit 0 }
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$w = $decoder.OrientedPixelWidth; $h = $decoder.OrientedPixelHeight
$max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
$scale = [Math]::Min(1.0, $max / [Math]::Max($w, $h))
$transform = New-Object Windows.Graphics.Imaging.BitmapTransform
if ($scale -lt 1.0) {
  $transform.ScaledWidth = [uint32][Math]::Floor($decoder.PixelWidth * $scale)
  $transform.ScaledHeight = [uint32][Math]::Floor($decoder.PixelHeight * $scale)
}
$bitmap = Await ($decoder.GetSoftwareBitmapAsync(
    [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,
    $transform,
    [Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,
    [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
$lines = foreach ($line in $result.Lines) {
  @{ t = $line.Text; words = @(foreach ($word in $line.Words) {
        $r = $word.BoundingRect
        @{ t = $word.Text; x = $r.X; y = $r.Y; w = $r.Width; h = $r.Height } }) }
}
@{ w = $bitmap.PixelWidth; h = $bitmap.PixelHeight; lines = @($lines) } |
  ConvertTo-Json -Depth 6 -Compress
''';
}
