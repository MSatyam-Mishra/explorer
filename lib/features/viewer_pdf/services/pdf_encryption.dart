import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Password-protects a PDF with the standard security handler, AES-256
/// (PDF 2.0, revision 6), the same password opening the file and allowing
/// everything.
///
/// PDFium (which does the rest of the editing) can't write encrypted files,
/// so this rewrites PDFium's own output: a full, uncompressed-xref save. Every
/// string and stream is encrypted with the file key and an /Encrypt
/// dictionary is added. Files it doesn't understand throw [FormatException].
abstract final class PdfEncryption {
  static Uint8List encrypt(Uint8List pdf, String password, {Random? random}) {
    final rng = random ?? Random.secure();
    Uint8List randomBytes(int n) =>
        Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

    final parsed = _PdfFile.parse(pdf);
    final fileKey = randomBytes(32);
    final pw = _passwordBytes(password);

    final userValidationSalt = randomBytes(8), userKeySalt = randomBytes(8);
    final u = _concat([
      _hash2B(pw, userValidationSalt, Uint8List(0)),
      userValidationSalt,
      userKeySalt,
    ]);
    final ue = _aesCbcNoPad(
      _hash2B(pw, userKeySalt, Uint8List(0)),
      Uint8List(16),
      fileKey,
    );

    final ownerValidationSalt = randomBytes(8), ownerKeySalt = randomBytes(8);
    final o = _concat([
      _hash2B(pw, ownerValidationSalt, u),
      ownerValidationSalt,
      ownerKeySalt,
    ]);
    final oe = _aesCbcNoPad(
      _hash2B(pw, ownerKeySalt, u),
      Uint8List(16),
      fileKey,
    );

    const permissions = -4; // Everything allowed.
    final permsBlock = Uint8List(16)
      ..buffer.asByteData().setInt32(0, permissions, Endian.little)
      ..setRange(4, 8, const [0xFF, 0xFF, 0xFF, 0xFF])
      ..[8] =
          0x54 // 'T': metadata is encrypted too.
      ..setRange(9, 12, ascii.encode('adb'))
      ..setRange(12, 16, randomBytes(4));
    final perms = _aesEcb(fileKey, permsBlock);

    final out = BytesBuilder(copy: false);
    final offsets = <int, int>{};
    out.add(ascii.encode('%PDF-${parsed.version}\n'));
    out.add(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    Uint8List encryptData(Uint8List data) {
      final iv = randomBytes(16);
      return _concat([iv, _aesCbcPkcs7(fileKey, iv, data)]);
    }

    for (final object in parsed.objects) {
      offsets[object.number] = out.length;
      final writer = _Writer(encryptData);
      out.add(ascii.encode('${object.number} ${object.generation} obj\n'));
      final stream = object.stream;
      if (stream != null) {
        final data = encryptData(stream);
        final dict = Map<String, _Obj>.of((object.value as _Dict).entries)
          ..['Length'] = _Number(data.length.toString());
        writer.write(_Dict(dict), encryptStrings: true);
        out
          ..add(writer.bytes)
          ..add(ascii.encode('\nstream\n'))
          ..add(data)
          ..add(ascii.encode('\nendstream\nendobj\n'));
      } else {
        writer.write(object.value, encryptStrings: true);
        out
          ..add(writer.bytes)
          ..add(ascii.encode('\nendobj\n'));
      }
    }

    String hex(Uint8List b) =>
        b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final encryptNumber = parsed.maxObjectNumber + 1;
    offsets[encryptNumber] = out.length;
    out.add(
      ascii.encode(
        '$encryptNumber 0 obj\n'
        '<</Filter/Standard/V 5/R 6/Length 256'
        '/CF<</StdCF<</AuthEvent/DocOpen/CFM/AESV3/Length 32>>>>'
        '/StmF/StdCF/StrF/StdCF'
        '/O<${hex(o)}>/U<${hex(u)}>/OE<${hex(oe)}>/UE<${hex(ue)}>'
        '/P $permissions/Perms<${hex(perms)}>/EncryptMetadata true>>\n'
        'endobj\n',
      ),
    );

    final size = encryptNumber + 1;
    final xref = out.length;
    final table = StringBuffer('xref\n0 $size\n0000000000 65535 f \n');
    for (var n = 1; n < size; n++) {
      final offset = offsets[n];
      table.write(
        offset == null
            ? '0000000000 65535 f \n'
            : '${offset.toString().padLeft(10, '0')} 00000 n \n',
      );
    }
    final id = parsed.id ?? randomBytes(16);
    final trailer = Map<String, _Obj>.of(parsed.trailer)
      ..remove('Prev')
      ..remove('XRefStm')
      ..['Size'] = _Number('$size')
      ..['Encrypt'] = _Ref(encryptNumber, 0)
      ..['ID'] = _Array([_Str(id, hex: true), _Str(id, hex: true)]);
    final trailerWriter = _Writer(null)
      ..write(_Dict(trailer), encryptStrings: false);
    out
      ..add(ascii.encode(table.toString()))
      ..add(ascii.encode('trailer\n'))
      ..add(trailerWriter.bytes)
      ..add(ascii.encode('\nstartxref\n$xref\n%%EOF\n'));
    return out.takeBytes();
  }

  static Uint8List _passwordBytes(String password) {
    final bytes = utf8.encode(password);
    return bytes.length > 127 ? bytes.sublist(0, 127) : bytes;
  }

  /// Algorithm 2.B (ISO 32000-2): the hardened revision 6 password hash.
  static Uint8List _hash2B(Uint8List password, Uint8List salt, Uint8List user) {
    var k = SHA256Digest().process(_concat([password, salt, user]));
    var round = 0;
    Uint8List e;
    while (true) {
      final block = _concat([password, k, user]);
      final k1 = Uint8List(block.length * 64);
      for (var i = 0; i < 64; i++) {
        k1.setRange(i * block.length, (i + 1) * block.length, block);
      }
      e = _aesCbcNoPad(k.sublist(0, 16), k.sublist(16, 32), k1);
      var sum = 0;
      for (var i = 0; i < 16; i++) {
        sum += e[i];
      }
      k = switch (sum % 3) {
        0 => SHA256Digest().process(e),
        1 => SHA384Digest().process(e),
        _ => SHA512Digest().process(e),
      };
      round++;
      if (round >= 64 && e.last <= round - 32) break;
    }
    return k.sublist(0, 32);
  }

  static Uint8List _aesCbcNoPad(Uint8List key, Uint8List iv, Uint8List data) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += 16) {
      cipher.processBlock(data, offset, out, offset);
    }
    return out;
  }

  static Uint8List _aesCbcPkcs7(Uint8List key, Uint8List iv, Uint8List data) {
    final pad = 16 - data.length % 16;
    final padded = Uint8List(data.length + pad)
      ..setRange(0, data.length, data)
      ..fillRange(data.length, data.length + pad, pad);
    return _aesCbcNoPad(key, iv, padded);
  }

  static Uint8List _aesEcb(Uint8List key, Uint8List block) {
    final engine = AESEngine()..init(true, KeyParameter(key));
    final out = Uint8List(16);
    engine.processBlock(block, 0, out, 0);
    return out;
  }

  static Uint8List _concat(List<Uint8List> parts) {
    final b = BytesBuilder(copy: false);
    for (final p in parts) {
      b.add(p);
    }
    return b.toBytes();
  }
}

// ---------------------------------------------------------------------------
// A minimal PDF object model: enough to re-serialise a regular file.
// ---------------------------------------------------------------------------

sealed class _Obj {
  const _Obj();
}

final class _Dict extends _Obj {
  const _Dict(this.entries);
  final Map<String, _Obj> entries;
  _Obj? operator [](String key) => entries[key];
}

final class _Array extends _Obj {
  const _Array(this.items);
  final List<_Obj> items;
}

final class _Str extends _Obj {
  const _Str(this.bytes, {this.hex = false});
  final Uint8List bytes;
  final bool hex;
}

/// A name, number, boolean, null or other bare token, kept verbatim.
final class _Token extends _Obj {
  const _Token(this.text);
  final String text;
}

final class _Number extends _Token {
  const _Number(super.text);
}

final class _Ref extends _Obj {
  const _Ref(this.number, this.generation);
  final int number;
  final int generation;
}

class _Object {
  _Object(this.number, this.generation, this.value, this.stream);
  final int number;
  final int generation;
  final _Obj value;
  final Uint8List? stream;
}

class _PdfFile {
  _PdfFile(this.version, this.objects, this.trailer, this.id);

  final String version;
  final List<_Object> objects;
  final Map<String, _Obj> trailer;
  final Uint8List? id;

  int get maxObjectNumber =>
      objects.fold(0, (m, o) => o.number > m ? o.number : m);

  static _PdfFile parse(Uint8List data) {
    final header = ascii.decode(
      data.sublist(0, min(16, data.length)),
      allowInvalid: true,
    );
    final versionMatch = RegExp(r'%PDF-(\d\.\d)').firstMatch(header);
    if (versionMatch == null) throw const FormatException('Not a PDF');
    var version = versionMatch[1]!;
    if (version.compareTo('1.7') < 0) version = '1.7';

    final parser = _Parser(data);
    final xrefAt = parser.findStartXref();
    final (offsets, trailer) = parser.readXrefTable(xrefAt);
    if (trailer['Encrypt'] != null) {
      throw const FormatException('Already encrypted');
    }

    Uint8List? id;
    final ids = trailer['ID'];
    if (ids is _Array && ids.items.isNotEmpty && ids.items.first is _Str) {
      id = (ids.items.first as _Str).bytes;
    }

    final objects = <_Object>[];
    final numbers = offsets.keys.toList()..sort();
    for (final number in numbers) {
      objects.add(parser.readObject(offsets[number]!, number, offsets));
    }
    for (final o in objects) {
      final v = o.value;
      if (v is _Dict) {
        final type = v['Type'];
        if (type is _Token &&
            (type.text == '/XRef' || type.text == '/ObjStm')) {
          throw const FormatException('Compressed object streams');
        }
      }
    }
    return _PdfFile(version, objects, trailer, id);
  }
}

class _Parser {
  _Parser(this.data);

  final Uint8List data;
  int pos = 0;

  static bool _isWhite(int c) =>
      c == 0x00 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0x20;

  static bool _isDelimiter(int c) =>
      c == 0x28 ||
      c == 0x29 ||
      c == 0x3C ||
      c == 0x3E ||
      c == 0x5B ||
      c == 0x5D ||
      c == 0x7B ||
      c == 0x7D ||
      c == 0x2F ||
      c == 0x25;

  int findStartXref() {
    final tail = ascii.decode(
      data.sublist(max(0, data.length - 1024)),
      allowInvalid: true,
    );
    final m = RegExp(r'startxref\s+(\d+)').allMatches(tail).lastOrNull;
    if (m == null) throw const FormatException('No startxref');
    return int.parse(m[1]!);
  }

  (Map<int, int>, Map<String, _Obj>) readXrefTable(int at) {
    pos = at;
    _skipWhite();
    if (_keyword() != 'xref') {
      throw const FormatException('Cross-reference streams are not supported');
    }
    final offsets = <int, int>{};
    while (true) {
      _skipWhite();
      final save = pos;
      final word = _keyword();
      if (word == 'trailer') break;
      pos = save;
      final start = _int();
      final count = _int();
      for (var i = 0; i < count; i++) {
        _skipWhite();
        final offset = _int();
        _int(); // generation
        _skipWhite();
        final kind = data[pos++];
        if (kind == 0x6E /* n */ && start + i != 0) offsets[start + i] = offset;
      }
    }
    final trailer = _value();
    if (trailer is! _Dict) throw const FormatException('Bad trailer');
    return (offsets, trailer.entries);
  }

  _Object readObject(int at, int expected, Map<int, int> offsets) {
    pos = at;
    final number = _int();
    final generation = _int();
    _skipWhite();
    if (_keyword() != 'obj' || number != expected) {
      throw FormatException('Object $expected not found at $at');
    }
    final value = _value();
    _skipWhite();
    final save = pos;
    if (_keyword() == 'stream' && value is _Dict) {
      if (data[pos] == 0x0D) pos++;
      if (data[pos] == 0x0A) pos++;
      final length = _streamLength(value['Length'], offsets);
      final stream = Uint8List.sublistView(data, pos, pos + length);
      return _Object(number, generation, value, Uint8List.fromList(stream));
    }
    pos = save;
    return _Object(number, generation, value, null);
  }

  int _streamLength(_Obj? length, Map<int, int> offsets) {
    if (length is _Number) return int.parse(length.text);
    if (length is _Ref) {
      final save = pos;
      final object = readObject(
        offsets[length.number]!,
        length.number,
        offsets,
      );
      pos = save;
      final v = object.value;
      if (v is _Number) return int.parse(v.text);
    }
    throw const FormatException('Stream without a length');
  }

  void _skipWhite() {
    while (pos < data.length) {
      final c = data[pos];
      if (_isWhite(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < data.length && data[pos] != 0x0A && data[pos] != 0x0D) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  String _keyword() {
    _skipWhite();
    final start = pos;
    while (pos < data.length &&
        !_isWhite(data[pos]) &&
        !_isDelimiter(data[pos])) {
      pos++;
    }
    return ascii.decode(data.sublist(start, pos), allowInvalid: true);
  }

  int _int() {
    final word = _keyword();
    final v = int.tryParse(word);
    if (v == null) throw FormatException('Expected a number, found "$word"');
    return v;
  }

  _Obj _value() {
    _skipWhite();
    if (pos >= data.length) throw const FormatException('Unexpected end');
    final c = data[pos];
    if (c == 0x3C && pos + 1 < data.length && data[pos + 1] == 0x3C) {
      pos += 2;
      final entries = <String, _Obj>{};
      while (true) {
        _skipWhite();
        if (data[pos] == 0x3E && data[pos + 1] == 0x3E) {
          pos += 2;
          return _Dict(entries);
        }
        final key = _value();
        if (key is! _Token || !key.text.startsWith('/')) {
          throw const FormatException('Bad dictionary key');
        }
        entries[key.text.substring(1)] = _value();
      }
    }
    if (c == 0x3C) return _hexString();
    if (c == 0x28) return _literalString();
    if (c == 0x5B) {
      pos++;
      final items = <_Obj>[];
      while (true) {
        _skipWhite();
        if (data[pos] == 0x5D) {
          pos++;
          return _Array(items);
        }
        items.add(_value());
      }
    }
    if (c == 0x2F) {
      final start = pos++;
      while (pos < data.length &&
          !_isWhite(data[pos]) &&
          !_isDelimiter(data[pos])) {
        pos++;
      }
      return _Token(latin1.decode(data.sublist(start, pos)));
    }
    final word = _keyword();
    if (word.isEmpty) throw FormatException('Unexpected byte $c at $pos');
    if (RegExp(r'^[+-]?\d+$').hasMatch(word)) {
      // "N G R" is a reference.
      final save = pos;
      try {
        final generation = _keyword();
        final r = _keyword();
        if (r == 'R' && int.tryParse(generation) != null) {
          return _Ref(int.parse(word), int.parse(generation));
        }
      } catch (_) {}
      pos = save;
      return _Number(word);
    }
    if (RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$').hasMatch(word)) {
      return _Number(word);
    }
    return _Token(word);
  }

  _Str _hexString() {
    pos++;
    final digits = <int>[];
    while (data[pos] != 0x3E) {
      final c = data[pos++];
      if (!_isWhite(c)) digits.add(c);
    }
    pos++;
    if (digits.length.isOdd) digits.add(0x30);
    final hex = ascii.decode(digits);
    final out = Uint8List(digits.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return _Str(out, hex: true);
  }

  _Str _literalString() {
    pos++;
    final out = BytesBuilder();
    var depth = 1;
    while (true) {
      var c = data[pos++];
      if (c == 0x28) {
        depth++;
      } else if (c == 0x29) {
        if (--depth == 0) break;
      } else if (c == 0x5C) {
        c = data[pos++];
        switch (c) {
          case 0x6E:
            c = 0x0A;
          case 0x72:
            c = 0x0D;
          case 0x74:
            c = 0x09;
          case 0x62:
            c = 0x08;
          case 0x66:
            c = 0x0C;
          case 0x0D:
            if (data[pos] == 0x0A) pos++;
            continue;
          case 0x0A:
            continue;
          default:
            if (c >= 0x30 && c <= 0x37) {
              var v = c - 0x30;
              for (
                var i = 0;
                i < 2 && data[pos] >= 0x30 && data[pos] <= 0x37;
                i++
              ) {
                v = v * 8 + data[pos++] - 0x30;
              }
              c = v & 0xFF;
            }
        }
      }
      out.addByte(c);
    }
    return _Str(out.toBytes());
  }
}

class _Writer {
  _Writer(this._encrypt);

  final Uint8List Function(Uint8List)? _encrypt;
  final _out = BytesBuilder();

  Uint8List get bytes => _out.toBytes();

  void _text(String s) => _out.add(latin1.encode(s));

  void write(_Obj value, {required bool encryptStrings}) {
    switch (value) {
      case _Dict(:final entries):
        _text('<<');
        for (final MapEntry(:key, value: v) in entries.entries) {
          _text('/$key ');
          write(v, encryptStrings: encryptStrings);
          _text(' ');
        }
        _text('>>');
      case _Array(:final items):
        _text('[');
        for (final item in items) {
          write(item, encryptStrings: encryptStrings);
          _text(' ');
        }
        _text(']');
      case _Str(:final bytes):
        final data = encryptStrings && _encrypt != null
            ? _encrypt(bytes)
            : bytes;
        _text('<');
        _text(data.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
        _text('>');
      case _Ref(:final number, :final generation):
        _text('$number $generation R');
      case _Token(:final text):
        _text(text);
    }
  }
}
