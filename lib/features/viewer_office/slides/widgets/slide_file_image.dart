import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../slide_loader.dart';
import '../slide_model.dart';

/// A picture stored in the presentation file, read (and inflated) in a
/// background isolate only when it's shown. Wrap in [ResizeImage] to decode
/// at display size.
@immutable
class SlideFileImage extends ImageProvider<SlideFileImage> {
  const SlideFileImage(this.ref);

  final SlideImageRef ref;

  @override
  Future<SlideFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<SlideFileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    SlideFileImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: ref.entry,
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await _SlideImageBytes.read(ref);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is SlideFileImage && other.ref == ref;

  @override
  int get hashCode => ref.hashCode;

  @override
  String toString() => 'SlideFileImage(${ref.entry})';
}

/// Encoded image bytes: a few reads at a time, one read per image even when
/// the slide and its thumbnail ask at once, and a small LRU so a size
/// change or an image-cache eviction doesn't hit the file again.
abstract final class _SlideImageBytes {
  static const _maxConcurrent = 3;
  static const _cacheLimit = 48 << 20;

  static int _running = 0;
  static final Queue<Completer<void>> _waiting = Queue();
  static final Map<SlideImageRef, Future<Uint8List>> _inFlight = {};
  static final LinkedHashMap<SlideImageRef, Uint8List> _recent =
      LinkedHashMap();
  static int _recentBytes = 0;

  static Future<Uint8List> read(SlideImageRef ref) {
    final hit = _recent.remove(ref);
    if (hit != null) {
      _recent[ref] = hit;
      return Future.value(hit);
    }
    return _inFlight[ref] ??= _withSlot(
      () => Isolate.run(() => readSlideImage(ref), debugName: 'slide-image'),
    ).then(_remember(ref)).whenComplete(() => _inFlight.remove(ref));
  }

  static Uint8List Function(Uint8List) _remember(SlideImageRef ref) => (bytes) {
    if (bytes.length <= _cacheLimit ~/ 4) {
      final old = _recent.remove(ref);
      if (old != null) _recentBytes -= old.length;
      _recent[ref] = bytes;
      _recentBytes += bytes.length;
      while (_recentBytes > _cacheLimit && _recent.isNotEmpty) {
        final oldest = _recent.keys.first;
        _recentBytes -= _recent.remove(oldest)!.length;
      }
    }
    return bytes;
  };

  static Future<T> _withSlot<T>(Future<T> Function() task) async {
    if (_running < _maxConcurrent) {
      _running++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future; // The finishing task hands its slot over.
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}
