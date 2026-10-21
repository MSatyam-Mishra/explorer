// Raw PDFium access for the edits pdfrx's API doesn't cover (annotations,
// drawing on pages, forms, saving without a password).
//
// PDFium isn't thread-safe: everything here must run on pdfrx's PDFium
// worker ([onPdfiumWorker]) or inside `PdfDocument.useNativeDocumentHandle`,
// which pauses that worker.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart' show Pdfrx, PdfrxEntryFunctions;

export 'package:pdfium_dart/pdfium_dart.dart'
    show
        FPDF_ANNOTATION,
        FPDF_DOCUMENT,
        FPDF_PAGE,
        FPDF_PAGEOBJECT,
        FS_QUADPOINTSF,
        FS_RECTF;

pdfium_bindings.PDFium? _pdfium;

/// The PDFium library (one per isolate; the process shares its state).
pdfium_bindings.PDFium get pdfium =>
    _pdfium ??= pdfium_bindings.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

/// Runs [task] with [message] on pdfrx's PDFium worker isolate.
///
/// Errors thrown by [task] are rethrown here (the worker itself would drop
/// them and never answer).
Future<R> onPdfiumWorker<M, R>(R Function(M message) task, M message) async {
  await PdfrxEntryFunctions.instance.init();
  final result = await PdfrxEntryFunctions.instance.compute(_guarded<M, R>, (
    task: task,
    message: message,
  ));
  final error = result.error;
  if (error != null) {
    Error.throwWithStackTrace(error, StackTrace.fromString(result.stack ?? ''));
  }
  return result.value as R;
}

({R? value, Object? error, String? stack}) _guarded<M, R>(
  ({R Function(M) task, M message}) call,
) {
  try {
    return (value: call.task(call.message), error: null, stack: null);
  } catch (e, stack) {
    // Only plain data crosses isolates reliably.
    final error = e is Exception || e is Error ? e : Exception('$e');
    return (value: null, error: error, stack: stack.toString());
  }
}

/// PDFium couldn't open or change a document.
class PdfiumException implements Exception {
  const PdfiumException(this.message, {this.code = 0});

  final String message;

  /// `FPDF_GetLastError()` when opening failed.
  final int code;

  bool get isPasswordError => code == pdfium_bindings.FPDF_ERR_PASSWORD;

  @override
  String toString() => 'PdfiumException: $message';

  static PdfiumException fromLastError() {
    final code = pdfium.FPDF_GetLastError();
    final reason = switch (code) {
      pdfium_bindings.FPDF_ERR_FILE => 'File not found or could not be opened',
      pdfium_bindings.FPDF_ERR_FORMAT => 'Not a PDF or the file is damaged',
      pdfium_bindings.FPDF_ERR_PASSWORD => 'Password required or incorrect',
      pdfium_bindings.FPDF_ERR_SECURITY => 'Unsupported security scheme',
      pdfium_bindings.FPDF_ERR_PAGE => 'Page not found or content error',
      _ => 'Unknown error ($code)',
    };
    return PdfiumException(reason, code: code);
  }
}

/// A document opened from bytes (or created) on the current isolate.
final class NativeDocument {
  NativeDocument._(this.handle, this._buffer);

  final pdfium_bindings.FPDF_DOCUMENT handle;

  /// PDFium reads from this memory for as long as the document is open.
  final Pointer<Uint8>? _buffer;

  static NativeDocument open(Uint8List bytes, {String? password}) {
    final buffer = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final pw = password == null ? nullptr : password.toNativeUtf8();
    try {
      final doc = pdfium.FPDF_LoadMemDocument64(
        buffer.cast(),
        bytes.length,
        pw.cast(),
      );
      if (doc == nullptr) {
        malloc.free(buffer);
        throw PdfiumException.fromLastError();
      }
      return NativeDocument._(doc, buffer);
    } finally {
      if (pw != nullptr) malloc.free(pw);
    }
  }

  static NativeDocument create() =>
      NativeDocument._(pdfium.FPDF_CreateNewDocument(), null);

  /// Wraps a document opened elsewhere (pdfrx); [close] leaves it open.
  static NativeDocument borrow(int address) => NativeDocument._(
    pdfium_bindings.FPDF_DOCUMENT.fromAddress(address),
    nullptr,
  );

  bool get _borrowed => _buffer == nullptr;

  int get pageCount => pdfium.FPDF_GetPageCount(handle);

  /// A full rewrite of the document (removed content is dropped).
  Uint8List save({bool removeSecurity = false}) => saveDocument(
    handle,
    flags:
        pdfium_bindings.FPDF_NO_INCREMENTAL |
        (removeSecurity ? pdfium_bindings.FPDF_REMOVE_SECURITY : 0),
  );

  T withPage<T>(int index, T Function(pdfium_bindings.FPDF_PAGE page) use) {
    final page = pdfium.FPDF_LoadPage(handle, index);
    if (page == nullptr) {
      throw PdfiumException('Page ${index + 1} could not be loaded');
    }
    try {
      return use(page);
    } finally {
      pdfium.FPDF_ClosePage(page);
    }
  }

  void close() {
    if (_borrowed) return;
    pdfium.FPDF_CloseDocument(handle);
    final buffer = _buffer;
    if (buffer != null) malloc.free(buffer);
  }
}

typedef _WriteBlock =
    Int Function(
      Pointer<pdfium_bindings.FPDF_FILEWRITE>,
      Pointer<Void>,
      UnsignedLong,
    );

/// Serialises [document] with `FPDF_SaveAsCopy`.
Uint8List saveDocument(
  pdfium_bindings.FPDF_DOCUMENT document, {
  required int flags,
}) {
  final out = BytesBuilder(copy: true);
  final writer = NativeCallable<_WriteBlock>.isolateLocal((
    Pointer<pdfium_bindings.FPDF_FILEWRITE> _,
    Pointer<Void> data,
    int size,
  ) {
    out.add(data.cast<Uint8>().asTypedList(size));
    return 1;
  }, exceptionalReturn: 0);
  final fileWrite = calloc<pdfium_bindings.FPDF_FILEWRITE>();
  try {
    fileWrite.ref.version = 1;
    fileWrite.ref.WriteBlock = writer.nativeFunction;
    if (pdfium.FPDF_SaveAsCopy(document, fileWrite, flags) == 0) {
      throw const PdfiumException('The PDF could not be saved');
    }
    return out.takeBytes();
  } finally {
    calloc.free(fileWrite);
    writer.close();
  }
}

/// [text] as a NUL-terminated UTF-16LE string for PDFium.
Pointer<pdfium_bindings.FPDF_WCHAR> wideString(String text, Allocator alloc) {
  final units = text.codeUnits;
  final p = alloc<pdfium_bindings.FPDF_WCHAR>(units.length + 1);
  final list = p.cast<Uint16>().asTypedList(units.length + 1);
  list.setAll(0, units);
  list[units.length] = 0;
  return p;
}

/// Reads a UTF-16LE string PDFium writes into a buffer of [bytes] bytes.
String readWideString(Pointer<Void> buffer, int bytes) {
  if (bytes <= 2) return '';
  final units = buffer.cast<Uint16>().asTypedList(bytes ~/ 2 - 1);
  return String.fromCharCodes(units);
}

typedef _GetBlock =
    Int Function(
      Pointer<Void>,
      UnsignedLong,
      Pointer<UnsignedChar>,
      UnsignedLong,
    );

/// An `FPDF_FILEACCESS` reading [bytes]; call [dispose] when PDFium is done.
final class MemoryFileAccess {
  MemoryFileAccess(Uint8List bytes)
    : _data = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length),
      _length = bytes.length,
      access = calloc<pdfium_bindings.FPDF_FILEACCESS>() {
    _data.asTypedList(bytes.length).setAll(0, bytes);
    _reader = NativeCallable<_GetBlock>.isolateLocal((
      Pointer<Void> _,
      int position,
      Pointer<UnsignedChar> buffer,
      int size,
    ) {
      if (position + size > _length) return 0;
      buffer
          .cast<Uint8>()
          .asTypedList(size)
          .setAll(
            0,
            _data.asTypedList(_length).sublist(position, position + size),
          );
      return 1;
    }, exceptionalReturn: 0);
    access.ref
      ..m_FileLen = bytes.length
      ..m_GetBlock = _reader.nativeFunction
      ..m_Param = nullptr;
  }

  final Pointer<Uint8> _data;
  final int _length;
  final Pointer<pdfium_bindings.FPDF_FILEACCESS> access;
  late final NativeCallable<_GetBlock> _reader;

  void dispose() {
    _reader.close();
    calloc.free(access);
    malloc.free(_data);
  }
}
