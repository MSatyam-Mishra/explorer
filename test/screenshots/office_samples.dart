import 'dart:convert';

import 'package:archive/archive.dart';

/// Small but realistic office files for the screenshot tests.

List<int> _zip(Map<String, String> parts) {
  final archive = Archive();
  parts.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

const _w =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

String _para(String text, {String? style, bool bold = false, String? color}) {
  final pPr = style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>';
  final rPr = bold || color != null
      ? '<w:rPr>${bold ? '<w:b/>' : ''}${color != null ? '<w:color w:val="$color"/>' : ''}</w:rPr>'
      : '';
  return '<w:p>$pPr<w:r>$rPr<w:t xml:space="preserve">$text</w:t></w:r></w:p>';
}

/// A two-page report with headings, coloured text and a table.
List<int> sampleDocx() {
  const body = 'Revenue grew across every region this quarter, led by strong '
      'subscription renewals and the launch of two new product lines. '
      'Operating costs stayed flat while headcount rose by four percent, '
      'and the board approved the revised plan for the second half. ';
  final paras = StringBuffer()
    ..write(_para('Quarterly report', style: 'Title'))
    ..write(_para('Prepared for the board · October 2026', color: '6B7280'))
    ..write(_para('Summary', style: 'Heading1'))
    ..write(_para(body * 2))
    ..write(_para('Highlights', style: 'Heading2'))
    ..write(_para('Customer retention reached a record 96 percent.', bold: true))
    ..write(_para(body))
    ..write('<w:tbl><w:tblPr><w:tblBorders>'
        '<w:top w:val="single" w:sz="4" w:color="999999"/><w:bottom w:val="single" w:sz="4" w:color="999999"/>'
        '<w:insideH w:val="single" w:sz="4" w:color="999999"/><w:insideV w:val="single" w:sz="4" w:color="999999"/>'
        '<w:left w:val="single" w:sz="4" w:color="999999"/><w:right w:val="single" w:sz="4" w:color="999999"/>'
        '</w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>');
  for (final row in [
    ['Region', 'Revenue', 'Growth'],
    ['North', '\$4.2M', '+12%'],
    ['South', '\$3.1M', '+8%'],
    ['West', '\$5.6M', '+15%'],
  ]) {
    paras.write('<w:tr>');
    for (final cell in row) {
      paras.write('<w:tc><w:tcPr><w:tcW w:w="3000" w:type="dxa"/></w:tcPr>'
          '${_para(cell, bold: row.first == 'Region')}</w:tc>');
    }
    paras.write('</w:tr>');
  }
  paras
    ..write('</w:tbl>')
    ..write(_para('Costs', style: 'Heading1'))
    ..write(_para(body * 3))
    ..write(_para('Outlook', style: 'Heading1'))
    ..write(_para(body * 2, color: '1F4E79'))
    ..write(_para('Risks', style: 'Heading2'))
    ..write(_para(body * 3));
  return _zip({
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    'word/_rels/document.xml.rels': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'word/styles.xml': '<?xml version="1.0" encoding="UTF-8"?><w:styles $_w>'
        '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>'
        '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:rPr><w:sz w:val="56"/><w:color w:val="111827"/></w:rPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/><w:color w:val="2F5496"/></w:rPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:spacing w:before="160" w:after="60"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:color w:val="2F5496"/></w:rPr></w:style>'
        '</w:styles>',
    'word/document.xml': '<?xml version="1.0" encoding="UTF-8"?><w:document $_w><w:body>'
        '$paras<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>'
        '</w:body></w:document>',
  });
}

const _p =
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';

String _shape(int id, String name, int x, int y, int w, int h, String text,
    {int size = 2400, bool bold = false, String color = '1F2937', String? fill, String? placeholder}) {
  final ph = placeholder == null ? '' : '<p:nvPr><p:ph type="$placeholder"/></p:nvPr>';
  final spPr = '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm>'
      '<a:prstGeom prst="${fill != null ? 'roundRect' : 'rect'}"><a:avLst/></a:prstGeom>'
      '${fill != null ? '<a:solidFill><a:srgbClr val="$fill"/></a:solidFill>' : '<a:noFill/>'}</p:spPr>';
  final paras = text
      .split('\n')
      .map((t) => '<a:p><a:r><a:rPr lang="en-US" sz="$size" b="${bold ? 1 : 0}"><a:latin typeface="Calibri"/>'
          '<a:solidFill><a:srgbClr val="$color"/></a:solidFill></a:rPr><a:t>$t</a:t></a:r></a:p>')
      .join();
  return '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr/>${ph.isEmpty ? '<p:nvPr/>' : ph}</p:nvSpPr>'
      '$spPr<p:txBody><a:bodyPr wrap="square" anchor="t"/><a:lstStyle/>$paras</p:txBody></p:sp>';
}

/// A five-slide deck with titles, text, coloured shapes and speaker notes.
List<int> samplePptx() {
  const cx = 12192000, cy = 6858000;
  final slides = <String>[];
  final titles = ['Quarterly review', 'Revenue by region', 'Highlights', 'Roadmap', 'Thank you'];
  for (var i = 0; i < titles.length; i++) {
    final bg = i == 0 ? '1E3A8A' : 'FFFFFF';
    final fg = i == 0 ? 'FFFFFF' : '111827';
    final shapes = StringBuffer()
      ..write(_shape(2, 'Title', 600000, i == 0 ? 2300000 : 500000, 11000000, 1100000, titles[i],
          size: i == 0 ? 5400 : 3600, bold: true, color: fg, placeholder: i == 0 ? 'ctrTitle' : 'title'));
    if (i == 0) {
      shapes.write(_shape(3, 'Subtitle', 600000, 3500000, 11000000, 700000,
          'Board meeting · October 2026', size: 2400, color: 'BFDBFE'));
    } else {
      shapes.write(_shape(3, 'Body', 600000, 1800000, 6200000, 4200000,
          'Revenue up 12% year on year\nRetention at a record 96%\nTwo product launches\nCosts flat',
          size: 2200, color: '374151', placeholder: 'body'));
      final colors = ['3B82F6', '22C55E', 'F59E0B'];
      for (var b = 0; b < 3; b++) {
        final h = 1200000 + ((b * 7 + i * 3) % 5) * 500000;
        shapes.write(_shape(10 + b, 'Bar $b', 7400000 + b * 1300000, 6000000 - h, 1000000, h, '',
            fill: colors[b]));
      }
    }
    slides.add('<?xml version="1.0" encoding="UTF-8"?><p:sld $_p><p:cSld>'
        '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="$bg"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>'
        '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
        '$shapes</p:spTree></p:cSld></p:sld>');
  }
  final parts = <String, String>{
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
        '${[for (var i = 1; i <= slides.length; i++) '<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'].join()}'
        '${[for (var i = 1; i <= slides.length; i++) '<Override PartName="/ppt/notesSlides/notesSlide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>'].join()}'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
        '</Relationships>',
    'ppt/presentation.xml': '<?xml version="1.0" encoding="UTF-8"?><p:presentation $_p>'
        '<p:sldIdLst>${[for (var i = 1; i <= slides.length; i++) '<p:sldId id="${255 + i}" r:id="rId$i"/>'].join()}</p:sldIdLst>'
        '<p:sldSz cx="$cx" cy="$cy"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
    'ppt/_rels/presentation.xml.rels': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 1; i <= slides.length; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide$i.xml"/>'].join()}'
        '</Relationships>',
  };
  for (var i = 0; i < slides.length; i++) {
    parts['ppt/slides/slide${i + 1}.xml'] = slides[i];
    parts['ppt/slides/_rels/slide${i + 1}.xml.rels'] = '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide${i + 1}.xml"/>'
        '</Relationships>';
    parts['ppt/notesSlides/notesSlide${i + 1}.xml'] = '<?xml version="1.0" encoding="UTF-8"?><p:notes $_p><p:cSld><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
        '${_shape(2, 'Notes', 0, 0, 6000000, 4000000, 'Speaker notes for ${titles[i]}: mention the renewal campaign and thank the regional teams.', placeholder: 'body')}'
        '</p:spTree></p:cSld></p:notes>';
  }
  return _zip(parts);
}
