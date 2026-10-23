import 'dart:typed_data';

/// Wraps one HEVC-coded picture (an Annex B stream, as FFmpeg's libx265
/// writes with `-f hevc`) in a HEIF file (.heic): the `ftyp`, the `meta`
/// box describing a single primary `hvc1` image item, and the coded data
/// in `mdat`. [width] and [height] are the coded picture's size.
Uint8List heicFromHevc(Uint8List annexB, {required int width, required int height}) {
  final nals = _nalUnits(annexB);
  List<Uint8List> ofType(int t) => [for (final n in nals) if (_type(n) == t) n];
  final vps = ofType(32), sps = ofType(33), pps = ofType(34);
  if (vps.isEmpty || sps.isEmpty || pps.isEmpty) {
    throw const FormatException('The HEVC stream has no parameter sets');
  }
  // The picture's coded slices, each with a 4-byte length.
  final data = BytesBuilder();
  for (final nal in nals) {
    if (_type(nal) < 32) {
      data
        ..add(_u32(nal.length))
        ..add(nal);
    }
  }
  final coded = data.takeBytes();

  final hvcC = _box('hvcC', _hvcC(sps.first, [vps.first, sps.first, pps.first]));
  final ispe = _fullBox('ispe', 0, 0, [..._u32(width), ..._u32(height)]);
  final pixi = _fullBox('pixi', 0, 0, [3, 8, 8, 8]);
  // sRGB colours as BT.601 limited-range YUV, as FFmpeg converts them.
  final colr = _box('colr', [...'nclx'.codeUnits, ..._u16(1), ..._u16(13), ..._u16(6), 0x00]);
  final ipco = _box('ipco', [...hvcC, ...ispe, ...pixi, ...colr]);
  // Item 1 has properties 1 (hvcC, essential), 2 (ispe), 3 (pixi), 4 (colr).
  final ipma = _fullBox('ipma', 0, 0, [..._u32(1), ..._u16(1), 4, 0x81, 0x02, 0x03, 0x04]);
  final iprp = _box('iprp', [...ipco, ...ipma]);
  final hdlr = _fullBox('hdlr', 0, 0, [..._u32(0), ...'pict'.codeUnits, ...List.filled(12, 0), 0]);
  final pitm = _fullBox('pitm', 0, 0, _u16(1));
  final infe = _fullBox('infe', 2, 0, [..._u16(1), ..._u16(0), ...'hvc1'.codeUnits, 0]);
  final iinf = _fullBox('iinf', 0, 0, [..._u16(1), ...infe]);
  final ftyp = _box('ftyp', [...'heic'.codeUnits, ..._u32(0), ...'mif1'.codeUnits, ...'heic'.codeUnits]);

  // iloc points at the data inside mdat, so its offset depends on the
  // sizes before it; iloc's own size doesn't depend on the offset.
  List<int> iloc(int offset) => _fullBox('iloc', 0, 0, [
        0x44, 0x00, // offset_size 4, length_size 4, base_offset_size 0
        ..._u16(1), // one item
        ..._u16(1), ..._u16(0), // item 1, this file
        ..._u16(1), ..._u32(offset), ..._u32(coded.length),
      ]);
  List<int> meta(int offset) => _fullBox('meta', 0, 0, [...hdlr, ...pitm, ...iloc(offset), ...iinf, ...iprp]);
  final dataOffset = ftyp.length + meta(0).length + 8;
  return Uint8List.fromList([...ftyp, ...meta(dataOffset), ..._box('mdat', coded)]);
}

int _type(Uint8List nal) => (nal[0] >> 1) & 0x3f;

/// The NAL units of an Annex B stream (start codes removed).
List<Uint8List> _nalUnits(Uint8List s) {
  final starts = <int>[];
  for (var i = 0; i + 2 < s.length; i++) {
    if (s[i] == 0 && s[i + 1] == 0 && s[i + 2] == 1) {
      starts.add(i + 3);
      i += 2;
    }
  }
  final units = <Uint8List>[];
  for (var k = 0; k < starts.length; k++) {
    var end = k + 1 < starts.length ? starts[k + 1] - 3 : s.length;
    while (end > starts[k] && s[end - 1] == 0) {
      end--; // trailing zero bytes / the 4-byte start code's extra zero
    }
    if (end > starts[k]) units.add(Uint8List.sublistView(s, starts[k], end));
  }
  return units;
}

/// The HEVCDecoderConfigurationRecord: profile, tier, level and format from
/// the SPS, then the parameter sets.
List<int> _hvcC(Uint8List sps, List<Uint8List> parameterSets) {
  final rbsp = _unescape(sps);
  // NAL header (2 bytes), then vps id (4) / max sub layers (3) / nesting (1).
  final ptl = rbsp.sublist(3, 3 + 12); // general profile_tier_level: 12 bytes
  final bits = _Bits(rbsp, (3 + 12) * 8);
  final subLayers = (rbsp[2] >> 1) & 0x07;
  if (subLayers > 0) {
    // Sub-layer flags: 2 bits each, padded to 8 entries.
    final present = <bool>[];
    for (var i = 0; i < subLayers; i++) {
      present.add(bits.bit() == 1);
      bits.bit(); // level present
    }
    for (var i = subLayers; i < 8; i++) {
      bits.skip(2);
    }
    for (var i = 0; i < subLayers; i++) {
      if (present[i]) bits.skip(88);
      bits.skip(8); // sub-layer level when present (x265 writes none)
    }
  }
  bits.ue(); // sps id
  final chroma = bits.ue();
  if (chroma == 3) bits.bit();
  bits.ue(); // width
  bits.ue(); // height
  if (bits.bit() == 1) {
    bits
      ..ue()
      ..ue()
      ..ue()
      ..ue();
  }
  final lumaDepth = bits.ue();
  final chromaDepth = bits.ue();

  final out = <int>[
    1, // configurationVersion
    ...ptl, // profile space/tier/idc, compatibility, constraints, level
    0xF0, 0x00, // min_spatial_segmentation_idc 0
    0xFC, // parallelismType 0
    0xFC | (chroma & 3),
    0xF8 | (lumaDepth & 7),
    0xF8 | (chromaDepth & 7),
    0x00, 0x00, // avgFrameRate
    0x0F, // constantFrameRate 0, one temporal layer, nested, 4-byte lengths
    parameterSets.length,
  ];
  for (final set in parameterSets) {
    out
      ..add(0x80 | _type(set)) // array complete
      ..addAll(_u16(1))
      ..addAll(_u16(set.length))
      ..addAll(set);
  }
  return out;
}

/// Removes emulation prevention bytes (00 00 03 → 00 00).
Uint8List _unescape(Uint8List nal) {
  final out = <int>[];
  var zeros = 0;
  for (final b in nal) {
    if (zeros >= 2 && b == 3) {
      zeros = 0;
      continue;
    }
    zeros = b == 0 ? zeros + 1 : 0;
    out.add(b);
  }
  return Uint8List.fromList(out);
}

class _Bits {
  _Bits(this.data, this.position);

  final Uint8List data;
  int position;

  int bit() {
    final byte = data[position >> 3];
    final value = (byte >> (7 - (position & 7))) & 1;
    position++;
    return value;
  }

  void skip(int n) => position += n;

  /// Exp-Golomb unsigned.
  int ue() {
    var zeros = 0;
    while (bit() == 0) {
      zeros++;
    }
    var value = 0;
    for (var i = 0; i < zeros; i++) {
      value = (value << 1) | bit();
    }
    return (1 << zeros) - 1 + value;
  }
}

List<int> _u16(int v) => [(v >> 8) & 0xff, v & 0xff];
List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

List<int> _box(String type, List<int> payload) => [..._u32(8 + payload.length), ...type.codeUnits, ...payload];

List<int> _fullBox(String type, int version, int flags, List<int> payload) =>
    _box(type, [version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff, ...payload]);
