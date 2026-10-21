import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/core/services/bookmark_service.dart';
import 'package:explorer/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:explorer/features/viewer_pdf/screens/pdf_page_canvas_screen.dart';
import 'package:explorer/features/viewer_pdf/screens/viewer_pdf_screen.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
// ignore: implementation_imports
import 'package:syncfusion_flutter_pdfviewer/src/common/pdfviewer_helper.dart'
    as sf;
// ignore: implementation_imports
import 'package:syncfusion_flutter_pdfviewer/src/control/pdf_page_view.dart';
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';

import '../support/screenshots.dart';
import 'doc_viewer_harness.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/pdf_viewer_screens_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File pdf;
  late List<int> pdfBytes;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    PdfViewerPlatform.instance = FakePdfRenderer(await renderSamplePages());
    // Phone screenshots: SfPdfViewer's touch layout (scroll head etc.).
    sf.kIsDesktop = false;
    dir = await sampleDir('pdf');
    pdfBytes = _samplePdf();
    pdf = File(p.join(dir.path, 'Quarterly report.pdf'));
    await pdf.writeAsBytes(pdfBytes);
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await dir.delete(recursive: true);
  });

  for (final (mode, device, size) in shotVariants) {
    final tag = '${mode.name}_$device';
    final phone = device == 'phone';

    testWidgets('pdf viewer $tag', (tester) async {
      await pumpViewer(
        tester,
        PdfViewerScreen(pdfFile: pdf),
        mode: mode,
        size: size,
        beforePush: () async {
          // BookmarkService caches in memory across tests.
          if ((await BookmarkService().getBookmarks(pdf.path)).isNotEmpty) {
            return;
          }
          await BookmarkService().saveLastReadPosition(pdf.path, 0);
          await BookmarkService().addBookmark(pdf.path, 0, 'Page 1');
          await BookmarkService().addBookmark(pdf.path, 2, 'Page 3');
        },
      );
      await settle(tester, rounds: 10);
      await renderPages(tester);
      await saveScreenshot(tester, 'pdf_read_$tag');

      // Overflow menu.
      await tester.tap(find.byTooltip('More options'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'pdf_menu_$tag');
      await dismissTop(tester);

      // Side panel: outline, bookmarks, pages (docked on tablets).
      if (phone) {
        await tester.tap(find.byTooltip('Outline, bookmarks and pages'));
        await settle(tester, rounds: 4);
      }
      await saveScreenshot(tester, 'pdf_outline_$tag');
      await tester.tap(find.text('Bookmarks').last);
      await settle(tester, rounds: 4);
      await saveScreenshot(tester, 'pdf_bookmarks_$tag');
      await tester.tap(find.text('Pages').last);
      await settle(tester, rounds: 10);
      await saveScreenshot(tester, 'pdf_pages_$tag');
      if (phone) {
        Scaffold.of(tester.element(find.byType(Drawer))).closeDrawer();
        await settle(tester, rounds: 8);
      } else {
        await tester.tap(find.text('Outline').last);
        await settle(tester, rounds: 3);
      }

      // Search.
      await tester.tap(find.byTooltip('Search'));
      await settle(tester, rounds: 3);
      await tester.enterText(find.byType(TextField).first, 'revenue');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester, rounds: 6);
      await renderPages(tester);
      await saveScreenshot(tester, 'pdf_search_$tag');
      await tester.tap(find.byTooltip('Close search'));
      await settle(tester, rounds: 3);

      // Edit mode toolbar.
      await tester.tap(find.byTooltip('Edit and annotate'));
      await settle(tester, rounds: 3);
      await tester.tap(find.byTooltip('Highlight'));
      await settle(tester, rounds: 3);
      await renderPages(tester);
      await saveScreenshot(tester, 'pdf_edit_$tag');

      if (!phone) return;
      // Dialogs (phone only).
      final ctx = tester.element(find.byType(PdfViewerScreen));
      showGoToPageDialog(ctx, pageCount: 6, currentPage: 2);
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'pdf_dialog_goto_$tag');
      await dismissTop(tester);
      showPdfPasswordDialog(ctx, fileName: 'Quarterly report.pdf', wrongPassword: true);
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'pdf_dialog_password_$tag');
      await dismissTop(tester);
      showUnsavedPdfDialog(ctx);
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'pdf_dialog_unsaved_$tag');
      await dismissTop(tester);
      showPdfColorPicker(ctx, const Color(0xFFFFEB3B));
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'pdf_dialog_color_$tag');
      await dismissTop(tester);
      showPdfConfirmDialog(
        ctx,
        title: 'Discard changes?',
        message: 'What you added to this page will be lost.',
        confirmLabel: 'Discard',
        destructive: true,
      );
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'pdf_dialog_confirm_$tag');
      await dismissTop(tester);
      showPdfTextInputDialog(ctx, title: 'Add text', hint: 'Type the text to place on the page', multiline: true);
      await settle(tester, rounds: 3);
      await tester.enterText(find.byType(TextField).last, 'Approved — J. Smith');
      await settle(tester, rounds: 2);
      await saveScreenshot(tester, 'pdf_dialog_text_$tag');
      await dismissTop(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('pdf page canvas $tag', (tester) async {
      await pumpViewer(
        tester,
        PdfPageCanvasScreen(
          documentBytes: Uint8List.fromList(pdfBytes),
          pageNumber: 1,
          meta: const PdfPageMeta(width: 595, height: 842, rotation: 0),
        ),
        mode: mode,
        size: size,
      );
      await settle(tester, rounds: 10);
      await saveScreenshot(tester, 'pdf_canvas_$tag');
    }, skip: !screenshotsEnabled);
  }

  testWidgets('pdf signature pad', (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await pumpViewer(
        tester,
        PdfPageCanvasScreen(
          documentBytes: Uint8List.fromList(pdfBytes),
          pageNumber: 1,
          meta: const PdfPageMeta(width: 595, height: 842, rotation: 0),
          start: PageCanvasStart.signature,
        ),
        mode: mode,
        size: const Size(390, 844),
      );
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'pdf_signature_${mode.name}_phone');
      await dismissTop(tester);
    }
  }, skip: !screenshotsEnabled);

  testWidgets('pdf locked', (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      final encrypted = File(p.join(dir.path, 'Locked.pdf'));
      await tester.runAsync(() => encrypted.writeAsBytes([1, 2, 3]));
      await pumpViewer(tester, PdfViewerScreen(pdfFile: encrypted), mode: mode, size: const Size(390, 844));
      await settle(tester, rounds: 8);
      await saveScreenshot(tester, 'pdf_error_${mode.name}_phone');
    }
  }, skip: !screenshotsEnabled);
}

/// SfPdfViewer doesn't request page bitmaps under `flutter test`; ask each
/// page for its image like the viewer does after scrolling.
Future<void> renderPages(WidgetTester tester) async {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final state in tester.stateList<PdfPageViewState>(find.byType(PdfPageView))) {
    state.getPageImage(size, 1);
  }
  await settle(tester, rounds: 4);
}

List<int> _samplePdf() {
  final doc = PdfDocument();
  doc.pageSettings.margins.all = 0;
  doc.pageSettings.size = const Size(595, 842);
  final pages = <PdfPage>[];
  for (final lines in samplePages) {
    final page = doc.pages.add();
    pages.add(page);
    for (final line in lines) {
      page.graphics.drawString(
        line.text,
        PdfStandardFont(
          PdfFontFamily.helvetica,
          line.size,
          style: line.bold ? PdfFontStyle.bold : PdfFontStyle.regular,
        ),
        bounds: Rect.fromLTWH(line.x, line.y, 520, line.size * 1.6),
      );
    }
  }
  for (var i = 0; i < pages.length; i++) {
    final bm = doc.bookmarks.add(i == 0 ? 'Quarterly report' : 'Section ${i + 1}');
    bm.destination = PdfDestination(pages[i], Offset.zero);
    if (i == 1) {
      for (final sub in ['Revenue', 'Costs', 'Outlook']) {
        bm.add(sub).destination = PdfDestination(pages[i], const Offset(0, 300));
      }
    }
  }
  final bytes = doc.saveSync();
  doc.dispose();
  return bytes;
}
