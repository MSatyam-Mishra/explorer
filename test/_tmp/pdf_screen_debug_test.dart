import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:explorer/features/viewer_pdf/screens/viewer_pdf_screen.dart';
import 'package:explorer/features/viewer_pdf/services/pdf_document_ops.dart';
import 'package:explorer/features/viewer_pdf/services/pdfium_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../screenshots/doc_viewer_harness.dart';

Uint8List _blank(int n) {
  final doc = NativeDocument.create();
  for (var i = 0; i < n; i++) {
    pdfium.FPDF_ClosePage(pdfium.FPDFPage_New(doc.handle, i, 300, 400));
  }
  final b = doc.save();
  doc.close();
  return b;
}

void main() {
  late File file;
  setUpAll(() async {
    await pdfrxInitialize();
    final dir = await Directory.systemTemp.createTemp('dbg');
    var b = await onPdfiumWorker(_blank, 3);
    b = await PdfDocumentOps.drawOnPage(b, 0, const [TextMark(position: Offset(20, 20), text: '•  Hello world', fontSize: 12, color: Color(0xFF000000))]);
    file = File('${dir.path}/a.pdf')..writeAsBytesSync(b);
  });

  testWidgets('screen', (tester) async {
    await pumpViewer(tester, PdfViewerScreen(pdfFile: file), mode: ThemeMode.light, size: const Size(390, 844));
    for (var i = 0; i < 12; i++) {
      await settle(tester, rounds: 1);
      final viewers = find.byType(PdfViewer).evaluate().length;
      final edit = find.byTooltip('Edit and annotate').evaluate().length;
      debugPrint('round $i viewers=$viewers edit=$edit');
      if (i > 5 && viewers > 0) {
        final c = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller;
        debugPrint('  controller ready=${c?.isReady}');
      }
    }
  });
}
