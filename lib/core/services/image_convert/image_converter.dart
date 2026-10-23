import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:explorer/core/services/background_tasks.dart';
import 'package:explorer/core/services/image_convert/heif_writer.dart';
import 'package:explorer/core/services/image_convert/image_formats.dart';
import 'package:explorer/core/services/video_downloader/desktop_tools.dart';
import 'package:explorer/features/clipboard/paste_task.dart' show freeName;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A new size for images: in pixels or percent. With [keepAspect] only one
/// side is needed (the other follows); with both given the image fits
/// inside them.
@immutable
class ResizeSpec {
  const ResizeSpec.pixels({this.width, this.height, this.keepAspect = true}) : percent = false;
  const ResizeSpec.percent({required double width, double? height, this.keepAspect = true})
      : width = width,
        height = height ?? width,
        percent = true;

  final num? width;
  final num? height;
  final bool percent;
  final bool keepAspect;

  /// The new size of a [w]×[h] image.
  (int, int) sizeFor(int w, int h) {
    int round(num v) => v.round().clamp(1, 30000);
    if (percent) {
      final sx = (width ?? 100) / 100;
      final sy = keepAspect ? sx : (height ?? 100) / 100;
      return (round(w * sx), round(h * sy));
    }
    final tw = width, th = height;
    if (!keepAspect) return (round(tw ?? w), round(th ?? h));
    if (tw != null && th != null) {
      final scale = [tw / w, th / h].reduce((a, b) => a < b ? a : b);
      return (round(w * scale), round(h * scale));
    }
    if (tw != null) return (round(tw), round(h * tw / w));
    if (th != null) return (round(w * th / h), round(th));
    return (w, h);
  }

  /// "50%" or "1280 px wide": for task titles.
  String get label {
    if (percent) return keepAspect || width == height ? '${width!.round()}%' : '${width!.round()}% × ${height!.round()}%';
    if (width != null && height != null) return '${width!.round()}×${height!.round()}';
    if (width != null) return '${width!.round()} px wide';
    return '${height!.round()} px tall';
  }
}

enum SupportKind { ready, needsFfmpeg, unavailable }

/// Whether this device can write a format, and why not.
@immutable
class FormatSupport {
  const FormatSupport(this.kind, [this.reason]);

  final SupportKind kind;
  final String? reason;

  bool get usable => kind != SupportKind.unavailable;
}

/// Converts and resizes images, in the background ([BackgroundTasks]).
///
/// PNG, JPEG, GIF, BMP, TIFF, ICO, TGA and SVG are written by the app
/// everywhere. WebP and HEIC use Android's own encoders; on Windows and
/// Linux WebP and AVIF use FFmpeg (the one the video downloader fetches,
/// or the system's), HEIC uses Windows' HEIF encoder or Linux's heif-enc.
/// Pictures are turned upright first. Nothing is overwritten unless asked.
abstract final class ImageConverter {
  static const _android = MethodChannel('explorer/image_convert');

  /// Formats the app writes itself.
  static const _dartFormats = {
    ImageFormat.png, ImageFormat.jpeg, ImageFormat.gif, ImageFormat.bmp,
    ImageFormat.tiff, ImageFormat.ico, ImageFormat.tga, ImageFormat.svg,
  };

  static bool? _heicAndroid;
  static bool? _heicWindows;

  /// Whether [format] can be written here.
  static Future<FormatSupport> support(ImageFormat format) async {
    if (_dartFormats.contains(format)) return const FormatSupport(SupportKind.ready);
    if (Platform.isAndroid) {
      switch (format) {
        case ImageFormat.webp:
          return const FormatSupport(SupportKind.ready);
        case ImageFormat.heic:
          _heicAndroid ??= await _android.invokeMethod<bool>('canEncodeHeic').catchError((_) => false) ?? false;
          return _heicAndroid!
              ? const FormatSupport(SupportKind.ready)
              : const FormatSupport(SupportKind.unavailable, 'This phone has no HEIC encoder.');
        default:
          return const FormatSupport(SupportKind.unavailable, "Android can't write AVIF yet.");
      }
    }
    if (format == ImageFormat.heic) {
      if (await ffmpeg() != null) return const FormatSupport(SupportKind.ready);
      if (Platform.isWindows) {
        // Trying Windows' encoder takes a moment: the menu doesn't wait.
        if (_heicWindows == null) {
          _heicWindows = false;
          unawaited(_windowsHasHeifEncoder().then((ok) => _heicWindows = ok));
        }
        if (_heicWindows!) return const FormatSupport(SupportKind.ready);
      } else if (_which('heif-enc') != null) {
        return const FormatSupport(SupportKind.ready);
      }
      return DesktopTools.ffmpegAsset() == null
          ? const FormatSupport(SupportKind.unavailable, 'Needs FFmpeg.')
          : const FormatSupport(SupportKind.needsFfmpeg);
    }
    // WebP and AVIF on computers: FFmpeg.
    if (await ffmpeg() != null) return const FormatSupport(SupportKind.ready);
    return DesktopTools.ffmpegAsset() == null
        ? const FormatSupport(SupportKind.unavailable, 'Needs FFmpeg.')
        : const FormatSupport(SupportKind.needsFfmpeg);
  }

  // ---- FFmpeg ----

  static Future<DesktopTools> desktopTools() async => DesktopTools(
        Directory(p.join((await getApplicationSupportDirectory()).path, 'video_downloader')),
      );

  /// FFmpeg: the app's (whose encoders are known), else the system's.
  static Future<String?> ffmpeg() async {
    if (debugFfmpeg != null) return debugFfmpeg;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return null;
    try {
      final own = (await desktopTools()).ffmpeg;
      if (own.existsSync()) return own.path;
    } catch (_) {
      // No app data folder (tests).
    }
    return _which('ffmpeg');
  }

  @visibleForTesting
  static String? debugFfmpeg;

  static String? _which(String name) {
    final dirs = (Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '')
        .split(Platform.isWindows ? ';' : ':');
    for (final dir in dirs) {
      if (dir.trim().isEmpty) continue;
      final candidate = p.join(dir, Platform.isWindows ? '$name.exe' : name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  // ---- Jobs ----

  /// Converts [sources] to [to] (beside them), or resizes them with [resize]
  /// (keeping their format; as copies unless [replace]). Returns the task.
  static BackgroundTask start(
    List<String> sources, {
    ImageFormat? to,
    ResizeSpec? resize,
    bool replace = false,
  }) {
    assert(to != null || resize != null);
    final n = sources.length;
    final what = n == 1 ? '"${p.basename(sources.single)}"' : '$n images';
    var cancelled = false;
    Process? running;
    final task = BackgroundTasks.instance.start(
      to != null ? 'Converting $what to ${to.label}' : 'Resizing $what to ${resize!.label}',
      message: 'Starting…',
      onCancel: () {
        cancelled = true;
        running?.kill();
      },
    );
    () async {
      final failed = <String>[];
      for (var i = 0; i < n && !cancelled; i++) {
        final source = sources[i];
        task.update(message: p.basename(source), progress: i / n);
        try {
          final out = await convertFile(
            source,
            to: to,
            resize: resize,
            replace: replace,
            onProcess: (process) => running = process,
          );
          task.outputs.add(out);
        } catch (e) {
          if (cancelled) break;
          failed.add('${p.basename(source)}: ${_describe(e)}');
        }
      }
      if (cancelled) {
        BackgroundTasks.instance.cancelled(task);
      } else if (failed.isEmpty) {
        BackgroundTasks.instance.finish(task,
            message: n == 1 ? 'Saved ${p.basename(task.outputs.single)}' : 'Done: $n images');
      } else if (task.outputs.isEmpty) {
        BackgroundTasks.instance.fail(task, failed.length == 1 ? failed.single : "None could be converted. ${failed.first}");
      } else {
        BackgroundTasks.instance.finish(task,
            message: 'Done: ${task.outputs.length} of $n. ${failed.length} failed (${failed.first})');
      }
    }();
    return task;
  }

  static String _describe(Object e) => switch (e) {
        ConvertException(:final message) => message,
        FileSystemException(:final message, :final osError) =>
          osError == null ? message : '$message (${osError.message.trim()})',
        _ => '$e',
      };

  /// Converts or resizes one file; returns the file written.
  static Future<String> convertFile(
    String source, {
    ImageFormat? to,
    ResizeSpec? resize,
    bool replace = false,
    void Function(Process process)? onProcess,
  }) async {
    final own = ImageFormat.of(source);
    var target = to ?? own ?? ImageFormat.png;
    // A resize keeps the format when it can be written here.
    if (to == null && !(await support(target)).usable) target = ImageFormat.png;
    final folder = p.dirname(source);
    final base = p.basenameWithoutExtension(source);
    final temp = await Directory.systemTemp.createTemp('explorer_convert_');
    try {
      final written = p.join(temp.path, 'out.${target.extension}');
      final (width, height) = await _convert(source, written, target, resize, temp.path, onProcess);
      final String destination;
      if (replace && to == null && target == own) {
        destination = source;
      } else {
        final name = to != null ? '$base.${target.extension}' : '$base ($width×$height).${target.extension}';
        destination = freeName(folder, name, isDirectory: false);
      }
      await _move(File(written), destination);
      return destination;
    } finally {
      unawaited(temp.delete(recursive: true).catchError((_) => temp));
    }
  }

  static Future<void> _move(File from, String to) async {
    try {
      await from.rename(to);
    } on FileSystemException {
      // Another drive (or replacing in place on Windows): copy over.
      await from.copy(to);
    }
  }

  /// Writes [source] as [target] to [out]; returns the size written.
  static Future<(int, int)> _convert(
    String source,
    String out,
    ImageFormat target,
    ResizeSpec? resize,
    String temp,
    void Function(Process)? onProcess,
  ) async {
    if (Platform.isAndroid && const {ImageFormat.jpeg, ImageFormat.png, ImageFormat.webp, ImageFormat.heic}.contains(target)) {
      final size = await _android.invokeMapMethod<String, Object?>('convert', {
        'path': source,
        'out': out,
        'format': target.name,
        'quality': 90,
        'width': resize?.width?.toDouble(),
        'height': resize?.height?.toDouble(),
        'percent': resize?.percent ?? false,
        'keepAspect': resize?.keepAspect ?? true,
      });
      if (size == null) throw const ConvertException("Couldn't read the image.");
      return (size['width']! as int, size['height']! as int);
    }
    // Pictures the app can't read itself (HEIC, AVIF) are read by the
    // system first.
    var input = source;
    if (!_dartReadable(source)) {
      input = p.join(temp, 'in.png');
      await _decodeExternally(source, input, onProcess);
    }
    final dart = _dartFormats.contains(target);
    final staged = dart ? out : p.join(temp, 'stage.png');
    final size = await Isolate.run(() => _dartStage(input, staged, dart ? target : ImageFormat.png, resize));
    if (dart) return size;
    switch (target) {
      case ImageFormat.webp:
        await _ffmpeg(['-i', staged, '-c:v', 'libwebp', '-quality', '90', '-pix_fmt', 'yuva420p', '-frames:v', '1', out], onProcess);
      case ImageFormat.avif:
        await _ffmpeg([
          '-i', staged,
          '-filter_complex', '[0:v]format=yuva444p,split[c][a];[a]alphaextract[al]',
          '-map', '[c]', '-map', '[al]',
          '-c:v', 'libaom-av1', '-still-picture', '1', '-crf', '28', '-b:v', '0', '-cpu-used', '6', out,
        ], onProcess);
      case ImageFormat.heic:
        if (await ffmpeg() != null) {
          // HEVC from FFmpeg, in a HEIF file of our own (FFmpeg writes no
          // HEIF). 4:2:0 needs even sides: an odd last row/column is cut.
          final hevc = p.join(temp, 'out.hevc');
          await _ffmpeg([
            '-i', staged,
            '-vf', 'crop=trunc(iw/2)*2:trunc(ih/2)*2,scale=out_color_matrix=bt601:out_range=tv,format=yuv420p',
            '-c:v', 'libx265', '-preset', 'medium', '-crf', '24',
            '-x265-params', 'log-level=error:colorprim=bt709:transfer=iec61966-2-1:colormatrix=smpte170m:range=limited',
            '-frames:v', '1', '-f', 'hevc', hevc,
          ], onProcess);
          final w = size.$1 ~/ 2 * 2, h = size.$2 ~/ 2 * 2;
          await File(out).writeAsBytes(heicFromHevc(await File(hevc).readAsBytes(), width: w, height: h));
          return (w, h);
        } else if (Platform.isWindows) {
          await _windowsImaging(staged, out, 'heic', onProcess);
        } else {
          await _run(_which('heif-enc')!, ['-q', '90', '-o', out, staged], onProcess);
        }
      default:
        throw ConvertException("Can't write ${target.label} here.");
    }
    return size;
  }

  static bool _dartReadable(String path) =>
      !const {'heic', 'heif', 'avif'}.contains(p.extension(path).toLowerCase().replaceFirst('.', ''));

  static Future<void> _decodeExternally(String source, String png, void Function(Process)? onProcess) async {
    if (Platform.isAndroid) {
      final ok = await _android.invokeMethod<bool>('decode', {'path': source, 'out': png});
      if (ok != true) throw const ConvertException("Couldn't read the image.");
      return;
    }
    if (Platform.isWindows) {
      try {
        return await _windowsImaging(source, png, 'png', onProcess);
      } on ConvertException {
        // No HEIF/AV1 extension: try FFmpeg.
      }
    }
    if (await ffmpeg() != null) {
      return _ffmpeg(['-i', source, '-frames:v', '1', png], onProcess);
    }
    final heifDec = _which('heif-dec') ?? _which('heif-convert');
    if (heifDec != null) return _run(heifDec, [source, png], onProcess);
    throw const ConvertException("This computer can't read HEIC or AVIF pictures (no FFmpeg).");
  }

  static Future<void> _ffmpeg(List<String> args, void Function(Process)? onProcess) async {
    final exe = await ffmpeg();
    if (exe == null) throw const ConvertException('Needs FFmpeg.');
    await _run(exe, ['-hide_banner', '-loglevel', 'error', '-y', ...args], onProcess);
  }

  static Future<void> _run(String exe, List<String> args, void Function(Process)? onProcess) async {
    final process = await Process.start(exe, args);
    onProcess?.call(process);
    final errors = StringBuffer();
    final err = process.stderr.transform(utf8.decoder).listen(errors.write);
    await process.stdout.drain<void>();
    final code = await process.exitCode;
    await err.cancel();
    if (code != 0) {
      final text = errors.toString().trim().split('\n').last;
      throw ConvertException(text.isEmpty ? '${p.basename(exe)} failed ($code)' : text);
    }
  }

  // ---- Windows imaging (WinRT): HEIC/AVIF in, HEIC out ----

  /// Whether Windows can write HEIC: its HEIF encoder also needs the
  /// HEVC Video Extensions, so a tiny picture is tried.
  static Future<bool> _windowsHasHeifEncoder() async {
    final temp = await Directory.systemTemp.createTemp('explorer_heic_check_');
    try {
      final png = p.join(temp.path, 'check.png');
      await File(png).writeAsBytes(img.encodePng(img.Image(width: 16, height: 16)));
      await _windowsImaging(png, p.join(temp.path, 'check.heic'), 'heic', null);
      return true;
    } catch (_) {
      return false;
    } finally {
      unawaited(temp.delete(recursive: true).catchError((_) => temp));
    }
  }

  static String get _powershell => p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');

  static Future<void> _windowsImaging(String input, String output, String format, void Function(Process)? onProcess) async {
    final script = File(p.join(Directory.systemTemp.path, 'explorer_imaging_1.ps1'));
    if (!await script.exists()) await script.writeAsString(_windowsScript);
    try {
      await _run(_powershell, [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path,
        p.normalize(p.absolute(input)), p.normalize(p.absolute(output)), format,
      ], onProcess);
    } on ConvertException {
      throw ConvertException(format == 'heic'
          ? "Windows couldn't write HEIC (needs the HEIF and HEVC Video Extensions)."
          : "Windows couldn't read this picture.");
    }
  }

  /// Reads any picture Windows can (upright) and writes PNG or HEIC.
  static const _windowsScript = r'''
param([string]$In, [string]$Out, [string]$Format)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$asAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Await($operation, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation)); $task.Wait() | Out-Null; $task.Result }
function AwaitAction($action) { $task = $asAction.Invoke($null, @($action)); $task.Wait() | Out-Null }
$source = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($In)) ([Windows.Storage.StorageFile])
$inStream = Await ($source.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($inStream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync(
    [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,
    (New-Object Windows.Graphics.Imaging.BitmapTransform),
    [Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,
    [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
$folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([IO.Path]::GetDirectoryName($Out))) ([Windows.Storage.StorageFolder])
$target = Await ($folder.CreateFileAsync([IO.Path]::GetFileName($Out), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
$outStream = Await ($target.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
$id = if ($Format -eq 'heic') { [Windows.Graphics.Imaging.BitmapEncoder]::HeifEncoderId } else { [Windows.Graphics.Imaging.BitmapEncoder]::PngEncoderId }
$encoder = Await ([Windows.Graphics.Imaging.BitmapEncoder]::CreateAsync($id, $outStream)) ([Windows.Graphics.Imaging.BitmapEncoder])
$encoder.SetSoftwareBitmap($bitmap)
AwaitAction ($encoder.FlushAsync())
$outStream.Dispose(); $inStream.Dispose()
''';
}

/// Why a picture couldn't be converted.
class ConvertException implements Exception {
  const ConvertException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// In a background isolate: reads [input], turns it upright, resizes it and
/// writes it as [format] to [output]. Returns the size written.
(int, int) _dartStage(String input, String output, ImageFormat format, ResizeSpec? resize) {
  final bytes = File(input).readAsBytesSync();
  var image = img.decodeNamedImage(input, bytes) ?? img.decodeImage(bytes);
  if (image == null) throw const ConvertException("Couldn't read the image.");
  image = img.bakeOrientation(image);
  if (image.format != img.Format.uint8 || image.hasPalette) {
    image = image.convert(format: img.Format.uint8, numChannels: image.hasAlpha ? 4 : 3);
  }
  if (resize != null) {
    final (w, h) = resize.sizeFor(image.width, image.height);
    if (w != image.width || h != image.height) {
      // Averaging keeps big reductions smooth; cubic suits the rest.
      final shrink = w * 2 < image.width || h * 2 < image.height;
      image = img.copyResize(image, width: w, height: h,
          interpolation: shrink ? img.Interpolation.average : img.Interpolation.cubic);
    }
  }
  final List<int> encoded = switch (format) {
    ImageFormat.png => img.encodePng(image, level: 6),
    ImageFormat.jpeg => img.encodeJpg(_flatten(image), quality: 90),
    ImageFormat.gif => img.encodeGif(image),
    ImageFormat.bmp => img.encodeBmp(image),
    ImageFormat.tiff => img.encodeTiff(image),
    ImageFormat.tga => img.encodeTga(image),
    ImageFormat.ico => img.encodeIco(_icon(image)),
    ImageFormat.svg => utf8.encode(_svg(image)),
    _ => throw ConvertException("Can't write ${format.label} here."),
  };
  File(output).writeAsBytesSync(encoded, flush: true);
  return format == ImageFormat.ico ? (256, 256) : (image.width, image.height);
}

/// JPEG has no transparency: put the picture on white.
img.Image _flatten(img.Image image) {
  if (!image.hasAlpha) return image;
  final white = img.Image(width: image.width, height: image.height)..clear(img.ColorRgb8(255, 255, 255));
  return img.compositeImage(white, image);
}

/// Icons are square, 256 px at most: the picture fitted, centred, on
/// transparency.
img.Image _icon(img.Image image) {
  final side = image.width > image.height ? image.width : image.height;
  final scale = side > 256 ? 256 / side : 1.0;
  final fitted = scale < 1
      ? img.copyResize(image, width: (image.width * scale).round(), height: (image.height * scale).round(),
          interpolation: img.Interpolation.average)
      : image;
  final size = scale < 1 ? 256 : side;
  final canvas = img.Image(width: size, height: size, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
  return img.compositeImage(canvas, fitted,
      dstX: (size - fitted.width) ~/ 2, dstY: (size - fitted.height) ~/ 2);
}

/// SVG has no pixels of its own: the picture goes inside as a PNG.
String _svg(img.Image image) {
  final png = base64Encode(img.encodePng(image, level: 6));
  final w = image.width, h = image.height;
  return '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
      'width="$w" height="$h" viewBox="0 0 $w $h">'
      '<image width="$w" height="$h" xlink:href="data:image/png;base64,$png"/></svg>';
}
