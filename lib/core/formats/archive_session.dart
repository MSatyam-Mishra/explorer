/// Background isolates for archives, so listing, decoding and extraction
/// never run on the UI isolate.
///
/// * [ArchiveSession]: a long-lived worker that owns one opened archive and
///   serves listings and whole-entry reads (archive browser, comic pages).
/// * [ExtractJob]: a short-lived worker per extraction, with progress,
///   conflict questions and a cancel that also works mid-decode (the
///   isolate is killed if it doesn't stop by itself).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'archive_backend.dart';
import 'archive_extract.dart';
import 'archive_index.dart';
import 'archive_open.dart';

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

sealed class ArcOpenEvent {
  const ArcOpenEvent();
}

/// Share of a compressed TAR read while listing.
class ArcOpenProgress extends ArcOpenEvent {
  const ArcOpenProgress(this.fraction);
  final double fraction;
}

/// Entries found so far (compressed TAR lists progressively).
class ArcOpenPartial extends ArcOpenEvent {
  const ArcOpenPartial(this.entries);
  final List<ArcEntry> entries;
}

class ArcOpenReady extends ArcOpenEvent {
  const ArcOpenReady(this.summary);
  final ArcSummary summary;
}

class ArcSummary {
  const ArcSummary({
    required this.formatLabel,
    required this.format,
    required this.index,
    required this.isSequential,
    required this.volumes,
    required this.archiveSize,
  });

  final String formatLabel;
  final ArcFormat format;
  final ArcIndex index;
  final bool isSequential;
  final List<String> volumes;

  /// Bytes on disk, all volumes together.
  final int archiveSize;

  List<ArcEntry> get entries => index.entries;
}

class _Req {
  const _Req(this.id, this.kind, [this.a, this.b]);
  final int id;
  final String kind;
  final Object? a;
  final Object? b;
}

class _Resp {
  const _Resp(this.id, {this.data, this.error, this.done = true});
  final int id;
  final Object? data;
  final ArcException? error;
  final bool done;
}

/// UI-side handle to a worker isolate that owns one opened archive.
class ArchiveSession {
  ArchiveSession._(this._isolate, this._port, this._events);

  final Isolate _isolate;
  final SendPort _port;
  final ReceivePort _events;
  final Map<int, StreamController<Object?>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;

  static Future<ArchiveSession> spawn() async {
    final rp = ReceivePort();
    final isolate = await Isolate.spawn(
      _sessionMain,
      rp.sendPort,
      debugName: 'archive-session',
      errorsAreFatal: false,
    );
    final completer = Completer<SendPort>();
    late ArchiveSession session;
    rp.listen((msg) {
      if (msg is SendPort) {
        completer.complete(msg);
        return;
      }
      if (msg is _Resp) session._onResp(msg);
    });
    final port = await completer.future;
    session = ArchiveSession._(isolate, port, rp);
    return session;
  }

  void _onResp(_Resp r) {
    final c = _pending[r.id];
    if (c == null) return;
    if (r.error != null) {
      c.addError(r.error!);
    } else if (r.data != null) {
      c.add(r.data);
    }
    if (r.done) {
      _pending.remove(r.id);
      c.close();
    }
  }

  Stream<Object?> _call(String kind, [Object? a, Object? b]) {
    if (_disposed) {
      return Stream.error(
        ArcException(ArcErrorKind.cancelled, 'The archive was closed.'),
      );
    }
    final id = _nextId++;
    final c = StreamController<Object?>();
    _pending[id] = c;
    _port.send(_Req(id, kind, a, b));
    return c.stream;
  }

  /// Opens [path] (closing any archive opened before) and lists it.
  Stream<ArcOpenEvent> open(String path, {String? password}) =>
      _call('open', path, password).cast<ArcOpenEvent>();

  /// Reads a whole entry (e.g. a comic page) into memory.
  Future<Uint8List> read(int index, {int maxBytes = 256 * 1024 * 1024}) async {
    final data = await _call('read', index, maxBytes).first;
    return (data as TransferableTypedData).materialize().asUint8List();
  }

  /// Re-opens the current archive with [password] for later reads.
  Future<void> setPassword(String? password) =>
      _call('password', password).drain<void>();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final c in _pending.values) {
      c.addError(ArcException(ArcErrorKind.cancelled, 'Closed.'));
      c.close();
    }
    _pending.clear();
    _port.send(const _Req(-1, 'close'));
    // Give the worker a moment to close files, then make sure it's gone.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _isolate.kill(priority: Isolate.immediate);
    _events.close();
  }
}

Future<void> _sessionMain(SendPort out) async {
  final rp = ReceivePort();
  out.send(rp.sendPort);
  ArcOpened? opened;
  String? path;
  var queue = Future<void>.value();

  Future<void> closeCurrent() async {
    final o = opened;
    opened = null;
    if (o != null) {
      try {
        await o.backend.close();
      } catch (_) {}
    }
  }

  Future<void> handle(_Req req) async {
    try {
      switch (req.kind) {
        case 'open':
          await closeCurrent();
          path = req.a as String;
          final o = await openArchive(
            path!,
            password: req.b as String?,
            onProgress: (f) =>
                out.send(_Resp(req.id, data: ArcOpenProgress(f), done: false)),
            onEntries: (batch) => out.send(
              _Resp(req.id, data: ArcOpenPartial(batch), done: false),
            ),
          );
          opened = o;
          var size = 0;
          for (final v in o.volumes) {
            try {
              size += File(v).lengthSync();
            } catch (_) {}
          }
          final summary = ArcSummary(
            formatLabel: o.backend.formatLabel,
            format: o.format,
            index: ArcIndex.build(o.backend.entries),
            isSequential: o.backend.isSequential,
            volumes: o.volumes,
            archiveSize: size,
          );
          out.send(_Resp(req.id, data: ArcOpenReady(summary)));
        case 'password':
          if (path != null) {
            await closeCurrent();
            opened = await openArchive(path!, password: req.a as String?);
          }
          out.send(_Resp(req.id));
        case 'read':
          final o = opened;
          if (o == null) {
            throw ArcException(ArcErrorKind.io, 'No archive is open.');
          }
          final index = req.a as int;
          final bytes = await readEntryBytes(
            o.backend,
            o.backend.entries[index],
            maxBytes: req.b as int,
          );
          out.send(
            _Resp(req.id, data: TransferableTypedData.fromList([bytes])),
          );
        case 'close':
          await closeCurrent();
          rp.close();
      }
    } catch (e) {
      final err = e is ArcException ? e : mapKoniError(e);
      out.send(_Resp(req.id, error: err));
    }
  }

  rp.listen((msg) {
    if (msg is _Req) {
      // One request at a time: backends aren't re-entrant.
      queue = queue.then((_) => handle(msg));
    }
  });
}

// ---------------------------------------------------------------------------
// Extraction jobs
// ---------------------------------------------------------------------------

class _JobInit {
  const _JobInit(this.port, this.request);
  final SendPort port;
  final ExtractRequest request;
}

/// One extraction running in its own isolate.
class ExtractJob {
  ExtractJob._(this._isolate, this._events, this.request);

  final Isolate _isolate;
  final ReceivePort _events;
  final ExtractRequest request;
  final _controller = StreamController<ExtractEvent>();
  SendPort? _control;
  String? _lastTemp;
  bool _finished = false;
  Timer? _killTimer;

  /// Progress, conflict questions, then exactly one [ExtractDone] or
  /// [ExtractFailed].
  Stream<ExtractEvent> get events => _controller.stream;

  static Future<ExtractJob> start(ExtractRequest request) async {
    final rp = ReceivePort();
    final isolate = await Isolate.spawn(
      _jobMain,
      _JobInit(rp.sendPort, request),
      debugName: 'archive-extract',
      errorsAreFatal: true,
      onExit: rp.sendPort,
    );
    final job = ExtractJob._(isolate, rp, request);
    rp.listen(job._onMessage);
    return job;
  }

  void _onMessage(Object? msg) {
    if (msg is SendPort) {
      _control = msg;
      return;
    }
    if (msg == null) {
      // Isolate exited.
      if (!_finished) {
        _finish(ExtractFailed(
          ArcException(ArcErrorKind.io, 'Extraction stopped unexpectedly.'),
        ));
      }
      return;
    }
    if (msg is ExtractEvent) {
      if (msg is ExtractProgress) _lastTemp = msg.tempPath;
      if (msg is ExtractDone || msg is ExtractFailed) {
        _finish(msg);
      } else if (!_finished) {
        _controller.add(msg);
      }
    }
  }

  void _finish(ExtractEvent last) {
    if (_finished) return;
    _finished = true;
    _killTimer?.cancel();
    _controller.add(last);
    _controller.close();
    _events.close();
  }

  /// Answers an [ExtractConflicts] question; null cancels.
  void answerConflicts(ConflictPolicy? policy) =>
      _control?.send(policy == null ? 'cancel' : policy.name);

  /// Stops the job, killing the isolate if it doesn't stop by itself.
  void cancel() {
    if (_finished) return;
    _control?.send('cancel');
    _killTimer ??= Timer(const Duration(milliseconds: 600), () {
      if (_finished) return;
      _isolate.kill(priority: Isolate.immediate);
      final temp = _lastTemp;
      if (temp != null) {
        try {
          final f = File(temp);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      _finish(ExtractFailed(
        ArcException(ArcErrorKind.cancelled, 'Extraction cancelled.'),
      ));
    });
  }
}

Future<void> _jobMain(_JobInit init) async {
  final out = init.port;
  final control = ReceivePort();
  out.send(control.sendPort);
  var cancelled = false;
  Completer<ConflictPolicy?>? answer;
  control.listen((msg) {
    if (msg == 'cancel') {
      cancelled = true;
      answer?.complete(null);
      answer = null;
    } else if (msg is String) {
      final policy = ConflictPolicy.values.where((p) => p.name == msg);
      answer?.complete(policy.isEmpty ? null : policy.first);
      answer = null;
    }
  });
  ArcOpened? opened;
  try {
    final req = init.request;
    opened = await openArchive(req.archivePath, password: req.password);
    var size = 0;
    for (final v in opened.volumes) {
      try {
        size += File(v).lengthSync();
      } catch (_) {}
    }
    final result = await runExtraction(
      opened.backend,
      req,
      emit: out.send,
      askConflicts: (count, examples) {
        final c = Completer<ConflictPolicy?>();
        answer = c;
        out.send(ExtractConflicts(count, examples));
        return c.future;
      },
      isCancelled: () => cancelled,
      archiveSize: size,
    );
    out.send(ExtractDone(result));
  } catch (e) {
    out.send(ExtractFailed(e is ArcException ? e : mapKoniError(e)));
  } finally {
    try {
      await opened?.backend.close();
    } catch (_) {}
    control.close();
  }
}
