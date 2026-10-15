import 'dart:io';

import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Previews a TrueType/OpenType font: metadata, sample text at several sizes
/// and a glyph grid.
class FontViewerScreen extends StatefulWidget {
  const FontViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<FontViewerScreen> createState() => _FontViewerScreenState();
}

class _FontViewerScreenState extends State<FontViewerScreen> {
  static int _loadCounter = 0;

  String? _family;
  Map<String, String> _info = const {};
  String? _error;
  final _sample = TextEditingController(
    text: 'The quick brown fox jumps over the lazy dog',
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final family = 'preview_font_${_loadCounter++}';
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      if (!mounted) return;
      setState(() {
        _family = family;
        _info = readFontNames(bytes);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'This font could not be loaded.\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _info['Full name'] ?? p.basename(widget.file.path);
    return ExplorerScaffold(
      title: title,
      body: _error != null
          ? Center(child: Text(_error!, textAlign: TextAlign.center))
          : _family == null
              ? const Center(child: CircularProgressIndicator())
              : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final style = TextStyle(fontFamily: _family, color: theme.colorScheme.onSurface);
    const glyphs =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        '!?@#\$%&*()[]{}<>/\\|+-=_.,:;\'"~^`€£¥©®™°±×÷¿¡ÀÉÎÕÜßæøñçΩπ';

    return ReadableWidth(
      maxWidth: 1000,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          DockedGlossyTopBar.contentTopInset(context) + 8,
          20,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (_info.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in _info.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(
                            text: '${e.key}: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: e.value),
                        ])),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _sample,
            decoration: const InputDecoration(
              labelText: 'Sample text',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          for (final size in const [12.0, 16.0, 24.0, 36.0, 48.0, 72.0])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${size.toInt()} pt', style: theme.textTheme.labelSmall),
                  Text(_sample.text, style: style.copyWith(fontSize: size)),
                ],
              ),
            ),
          const Divider(height: 32),
          Text('Glyphs', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final ch in glyphs.runes.map(String.fromCharCode))
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(ch, style: style.copyWith(fontSize: 26)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Reads human-readable entries from an OpenType `name` table.
Map<String, String> readFontNames(Uint8List bytes) {
  const labels = {
    4: 'Full name',
    1: 'Family',
    2: 'Style',
    5: 'Version',
    9: 'Designer',
    8: 'Manufacturer',
    0: 'Copyright',
    13: 'License',
  };
  final result = <String, String>{};
  try {
    final data = ByteData.sublistView(bytes);
    final numTables = data.getUint16(4);
    int? nameOffset;
    for (var i = 0; i < numTables; i++) {
      final rec = 12 + i * 16;
      final tag = String.fromCharCodes(bytes.sublist(rec, rec + 4));
      if (tag == 'name') {
        nameOffset = data.getUint32(rec + 8);
        break;
      }
    }
    if (nameOffset == null) return result;
    final count = data.getUint16(nameOffset + 2);
    final storage = nameOffset + data.getUint16(nameOffset + 4);
    final found = <int, String>{};
    for (var i = 0; i < count; i++) {
      final rec = nameOffset + 6 + i * 12;
      final platform = data.getUint16(rec);
      final language = data.getUint16(rec + 4);
      final nameId = data.getUint16(rec + 6);
      final length = data.getUint16(rec + 8);
      final offset = storage + data.getUint16(rec + 10);
      if (!labels.containsKey(nameId) || offset + length > bytes.length) continue;
      String value;
      if (platform == 3 || platform == 0) {
        // Prefer English (0x409) Windows names; take others only if missing.
        if (platform == 3 && language != 0x409 && found.containsKey(nameId)) continue;
        final units = <int>[
          for (var j = 0; j + 1 < length; j += 2)
            data.getUint16(offset + j),
        ];
        value = String.fromCharCodes(units);
      } else if (platform == 1) {
        if (found.containsKey(nameId)) continue;
        value = String.fromCharCodes(bytes.sublist(offset, offset + length));
      } else {
        continue;
      }
      if (value.trim().isNotEmpty) found[nameId] = value.trim();
    }
    for (final id in labels.keys) {
      final v = found[id];
      if (v != null) result[labels[id]!] = v;
    }
  } catch (_) {
    // Malformed tables just mean no metadata.
  }
  return result;
}
