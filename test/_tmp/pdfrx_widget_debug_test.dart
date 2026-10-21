import 'dart:typed_data';

import 'package:explorer/features/viewer_pdf/services/pdfium_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

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
  late Uint8List bytes;
  setUpAll(() async {
    await pdfrxInitialize();
    bytes = await onPdfiumWorker(_blank, 3);
  });

  testWidgets('pdfrx viewer becomes ready in a widget test', (tester) async {
    final controller = PdfViewerController();
    var ready = false;
    await tester.pumpWidget(MaterialApp(
      home: PdfViewer.data(bytes, sourceName: 'x', controller: controller,
          params: PdfViewerParams(onViewerReady: (d, c) => ready = true,
            errorBannerBuilder: (context, error, st, ref) { debugPrint('ERROR $error'); return Text('$error'); })),
    ));
    for (var i = 0; i < 40 && !ready; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('ready=$ready isReady=${controller.isReady}');
    expect(ready, isTrue);
  });
}
