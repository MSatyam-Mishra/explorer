// syncfusion_flutter_pdf has no public API to move an existing page. Moving
// it by rewriting the page tree keeps its annotations, links, form fields and
// bookmark targets intact, which redrawing the page as a template would lose.
// ignore_for_file: implementation_imports

import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/io/pdf_constants.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/io/pdf_cross_table.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/pages/pdf_page.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/pdf_document/pdf_document.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/primitives/pdf_array.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/primitives/pdf_dictionary.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/primitives/pdf_number.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/implementation/primitives/pdf_reference_holder.dart';
import 'package:syncfusion_flutter_pdf/src/pdf/interfaces/pdf_interface.dart';

/// Attributes a page may inherit from its ancestors in the page tree.
const _inheritable = <String>[
  PdfDictionaryProperties.resources,
  PdfDictionaryProperties.mediaBox,
  PdfDictionaryProperties.cropBox,
  PdfDictionaryProperties.rotate,
];

/// Rebuilds the page tree of a loaded [document] so its pages appear in
/// [order]. [order] must contain every page of the document exactly once.
///
/// The tree is flattened into the root `Pages` node. Inherited attributes are
/// copied onto each page first so nothing changes visually.
///
/// The document must be saved (and reloaded if it needs further edits)
/// right after this call: [PdfPageCollection] caches tree nodes internally.
void reorderPdfPages(PdfDocument document, List<PdfPage> order) {
  final helper = PdfDocumentHelper.getHelper(document);
  final root = PdfCrossTable.dereference(
    helper.catalog[PdfDictionaryProperties.pages],
  );
  if (root is! PdfDictionary) {
    throw StateError('The document has no page tree');
  }

  final kids = PdfArray();
  for (final page in order) {
    final dictionary = PdfPageHelper.getHelper(page).dictionary;
    if (dictionary == null) {
      throw StateError('Page has no dictionary');
    }
    for (final key in _inheritable) {
      if (dictionary.containsKey(key)) continue;
      final inherited = _inheritedValue(dictionary, key);
      if (inherited != null) dictionary[key] = inherited;
    }
    dictionary[PdfDictionaryProperties.parent] = PdfReferenceHolder(root);
    kids.add(PdfReferenceHolder(dictionary));
  }
  root[PdfDictionaryProperties.kids] = kids;
  root[PdfDictionaryProperties.count] = PdfNumber(order.length);
}

/// The raw (possibly indirect) value of [key] on the nearest ancestor of
/// [page], so shared resources stay shared instead of being inlined.
IPdfPrimitive? _inheritedValue(PdfDictionary page, String key) {
  var node = PdfCrossTable.dereference(page[PdfDictionaryProperties.parent]);
  var guard = 0;
  while (node is PdfDictionary && guard++ < 64) {
    final value = node[key];
    if (value != null) return value;
    node = PdfCrossTable.dereference(node[PdfDictionaryProperties.parent]);
  }
  return null;
}
