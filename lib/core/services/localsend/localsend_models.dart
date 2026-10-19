// LocalSend protocol v2 (https://github.com/localsend/protocol) data types.
//
// Pure Dart (no Flutter imports) so the protocol code can be exercised from a
// plain `dart run` harness.

import 'dart:developer' as developer;
import 'dart:math';

/// Protocol constants (section 1 of the spec).
abstract final class LsConst {
  static const int defaultPort = 53317;
  static const String multicastGroup = '224.0.0.167';

  /// Protocol version this implementation speaks (major.minor).
  static const String protocolVersion = '2.2';

  static const String apiPrefix = '/api/localsend/v2';
}

/// Lightweight logging hook; the harness and the app can redirect it.
abstract final class LsLog {
  static void Function(String message) handler = _defaultHandler;

  static void _defaultHandler(String message) =>
      developer.log(message, name: 'localsend');

  static void d(String message) => handler(message);
}

/// Device type (section 7.1). Unknown values fall back to [desktop].
enum LsDeviceType {
  mobile,
  desktop,
  web,
  headless,
  server;

  static LsDeviceType? parse(Object? value) {
    if (value is! String || value.isEmpty) return null;
    for (final type in values) {
      if (type.name == value.toLowerCase()) return type;
    }
    return desktop;
  }
}

enum LsProtocol {
  http,
  https;

  static LsProtocol? parse(Object? value) {
    if (value is! String) return null;
    switch (value.toLowerCase()) {
      case 'http':
        return http;
      case 'https':
        return https;
    }
    return null;
  }
}

/// The information a device announces about itself (announcement, register
/// request/response, info, prepare-upload `info`).
class LsDeviceInfo {
  const LsDeviceInfo({
    required this.alias,
    required this.version,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    this.deviceModel,
    this.deviceType,
    this.download = false,
  });

  final String alias;
  final String version;
  final String? deviceModel;
  final LsDeviceType? deviceType;
  final String fingerprint;
  final int port;
  final LsProtocol protocol;
  final bool download;

  /// Major protocol version, or null when missing/garbled (e.g. v1 messages
  /// carry no version at all).
  int? get majorVersion => lsMajorVersion(version);

  Map<String, dynamic> _base() => {
    'alias': alias,
    'version': version,
    if (deviceModel != null) 'deviceModel': deviceModel,
    if (deviceType != null) 'deviceType': deviceType!.name,
    'fingerprint': fingerprint,
  };

  /// Body of `POST /register` and the `info` object of prepare-upload.
  Map<String, dynamic> toRegisterJson() => {
    ..._base(),
    'port': port,
    'protocol': protocol.name,
    'download': download,
  };

  /// UDP multicast message.
  Map<String, dynamic> toAnnouncementJson({required bool announce}) => {
    ...toRegisterJson(),
    'announce': announce,
  };

  /// Response of `POST /register` and `GET /info`.
  Map<String, dynamic> toInfoJson() => {..._base(), 'download': download};

  /// Parses any of the shapes above. [port] / [protocol] fill in values that
  /// responses do not carry. Returns null when required fields are missing.
  static LsDeviceInfo? tryParse(
    Object? json, {
    int? port,
    LsProtocol? protocol,
  }) {
    if (json is! Map) return null;
    final alias = json['alias'];
    if (alias is! String) return null;
    final version = json['version'];
    final rawPort = json['port'];
    return LsDeviceInfo(
      alias: alias,
      version: version is String ? version : '1.0',
      deviceModel: json['deviceModel'] is String ? json['deviceModel'] : null,
      deviceType: LsDeviceType.parse(json['deviceType']),
      fingerprint: json['fingerprint'] is String ? json['fingerprint'] : '',
      port: rawPort is int
          ? rawPort
          : (rawPort is num ? rawPort.toInt() : (port ?? LsConst.defaultPort)),
      protocol:
          LsProtocol.parse(json['protocol']) ?? protocol ?? LsProtocol.https,
      download: json['download'] == true,
    );
  }

  LsDeviceInfo copyWith({
    String? alias,
    String? deviceModel,
    LsDeviceType? deviceType,
    String? fingerprint,
    int? port,
    LsProtocol? protocol,
  }) => LsDeviceInfo(
    alias: alias ?? this.alias,
    version: version,
    deviceModel: deviceModel ?? this.deviceModel,
    deviceType: deviceType ?? this.deviceType,
    fingerprint: fingerprint ?? this.fingerprint,
    port: port ?? this.port,
    protocol: protocol ?? this.protocol,
    download: download,
  );
}

int? lsMajorVersion(String version) =>
    int.tryParse(version.split('.').first.trim());

/// How a peer was found.
enum LsDiscoverySource { multicast, register, scan, manual }

/// A peer on the network.
class LsDevice {
  const LsDevice({
    required this.ip,
    required this.info,
    required this.lastSeen,
    required this.source,
  });

  final String ip;
  final LsDeviceInfo info;
  final DateTime lastSeen;
  final LsDiscoverySource source;

  String get alias => info.alias;
  int get port => info.port;
  LsProtocol get protocol => info.protocol;
  String get fingerprint => info.fingerprint;
  String get key => fingerprint.toUpperCase();

  Uri uri(String route, [Map<String, String>? query]) => Uri(
    scheme: protocol.name,
    host: ip,
    port: port,
    path: '${LsConst.apiPrefix}/$route',
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  LsDevice copyWith({String? ip, LsDeviceInfo? info, DateTime? lastSeen}) =>
      LsDevice(
        ip: ip ?? this.ip,
        info: info ?? this.info,
        lastSeen: lastSeen ?? this.lastSeen,
        source: source,
      );
}

/// File metadata in prepare-upload.
class LsFileDto {
  const LsFileDto({
    required this.id,
    required this.fileName,
    required this.size,
    required this.fileType,
    this.sha256,
    this.preview,
    this.modified,
    this.accessed,
  });

  final String id;

  /// May contain `/`-separated relative paths (folders).
  final String fileName;
  final int size;
  final String fileType;
  final String? sha256;
  final String? preview;
  final DateTime? modified;
  final DateTime? accessed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'size': size,
    'fileType': fileType,
    if (sha256 != null) 'sha256': sha256,
    if (preview != null) 'preview': preview,
    if (modified != null || accessed != null)
      'metadata': {
        if (modified != null) 'modified': modified!.toUtc().toIso8601String(),
        if (accessed != null) 'accessed': accessed!.toUtc().toIso8601String(),
      },
  };

  static LsFileDto? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['fileName'];
    final size = json['size'];
    if (id is! String || name is! String || size is! num || size < 0) {
      return null;
    }
    final metadata = json['metadata'];
    DateTime? time(String key) {
      if (metadata is! Map) return null;
      final v = metadata[key];
      return v is String ? DateTime.tryParse(v) : null;
    }

    return LsFileDto(
      id: id,
      fileName: name,
      size: size.toInt(),
      fileType: json['fileType'] is String
          ? json['fileType']
          : 'application/octet-stream',
      sha256: json['sha256'] is String ? json['sha256'] : null,
      preview: json['preview'] is String ? json['preview'] : null,
      modified: time('modified'),
      accessed: time('accessed'),
    );
  }
}

enum LsErrorKind {
  declined,
  pinRequired,
  invalidPin,
  tooManyRequests,
  busy,
  invalidToken,
  checksumMismatch,
  badRequest,
  notFound,
  receiverError,
  timeout,
  unreachable,
  tls,
  fingerprintMismatch,
  cancelled,
  cancelledByPeer,
  io,
  protocol,
  unknown,
}

class LsException implements Exception {
  const LsException(this.kind, [this.detail, this.statusCode]);

  final LsErrorKind kind;
  final String? detail;
  final int? statusCode;

  /// Maps an HTTP error status of a peer (sections 4.1-4.3).
  factory LsException.fromStatus(
    int status,
    String body, {
    bool pinSent = false,
    bool upload = false,
  }) {
    final message = _messageOf(body);
    final kind = switch (status) {
      400 => LsErrorKind.badRequest,
      401 => pinSent ? LsErrorKind.invalidPin : LsErrorKind.pinRequired,
      403 => upload ? LsErrorKind.invalidToken : LsErrorKind.declined,
      404 => LsErrorKind.notFound,
      409 => LsErrorKind.busy,
      422 => LsErrorKind.checksumMismatch,
      429 => LsErrorKind.tooManyRequests,
      _ when status >= 500 => LsErrorKind.receiverError,
      _ => LsErrorKind.unknown,
    };
    return LsException(kind, message, status);
  }

  static String? _messageOf(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    final match = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(trimmed);
    if (match != null) return match.group(1);
    return trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
  }

  /// Text for the user.
  String get message => switch (kind) {
    LsErrorKind.declined => 'The receiver declined the transfer.',
    LsErrorKind.pinRequired => 'The receiver requires a PIN.',
    LsErrorKind.invalidPin => 'Wrong PIN.',
    LsErrorKind.tooManyRequests =>
      'Too many wrong PIN attempts. Try again later.',
    LsErrorKind.busy =>
      'The receiver is busy with another transfer. Try again later.',
    LsErrorKind.invalidToken =>
      'The receiver no longer accepts this transfer (it may have been cancelled).',
    LsErrorKind.checksumMismatch =>
      'The file arrived damaged (checksum mismatch).',
    LsErrorKind.badRequest => 'The receiver rejected the request.',
    LsErrorKind.notFound =>
      'The device does not support LocalSend protocol v2.',
    LsErrorKind.receiverError =>
      'The receiver failed to save the file${detail == null ? '' : ': $detail'}.',
    LsErrorKind.timeout => 'The device did not respond in time.',
    LsErrorKind.unreachable =>
      'Could not connect to the device. Check that both devices are on the same network.',
    LsErrorKind.tls =>
      'Secure connection failed${detail == null ? '' : ': $detail'}.',
    LsErrorKind.fingerprintMismatch =>
      'The device presented a different certificate than announced.',
    LsErrorKind.cancelled => 'Cancelled.',
    LsErrorKind.cancelledByPeer => 'The other device cancelled the transfer.',
    LsErrorKind.io => 'File error${detail == null ? '' : ': $detail'}.',
    LsErrorKind.protocol =>
      'Unexpected answer from the device${detail == null ? '' : ': $detail'}.',
    LsErrorKind.unknown =>
      'Transfer failed${statusCode == null ? '' : ' (HTTP $statusCode)'}${detail == null ? '' : ': $detail'}.',
  };

  @override
  String toString() =>
      'LsException(${kind.name}${statusCode == null ? '' : ', $statusCode'}${detail == null ? '' : ', $detail'})';
}

final Random _secureRandom = Random.secure();

/// Random UUID v4 string (session ids, file ids, tokens).
String lsRandomId() {
  final b = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int from, int to) => b
      .sublist(from, to)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

const _aliasAdjectives = [
  'Adorable',
  'Beautiful',
  'Big',
  'Bright',
  'Calm',
  'Clean',
  'Clever',
  'Cool',
  'Cute',
  'Eager',
  'Fancy',
  'Fast',
  'Friendly',
  'Gentle',
  'Happy',
  'Jolly',
  'Kind',
  'Lively',
  'Lucky',
  'Mighty',
  'Nice',
  'Polite',
  'Proud',
  'Quick',
  'Quiet',
  'Shiny',
  'Smart',
  'Sunny',
  'Swift',
  'Witty',
];

const _aliasFruits = [
  'Apple',
  'Apricot',
  'Avocado',
  'Banana',
  'Blueberry',
  'Cherry',
  'Coconut',
  'Cranberry',
  'Date',
  'Fig',
  'Grape',
  'Guava',
  'Kiwi',
  'Lemon',
  'Lime',
  'Lychee',
  'Mango',
  'Melon',
  'Orange',
  'Papaya',
  'Peach',
  'Pear',
  'Pineapple',
  'Plum',
  'Raspberry',
  'Strawberry',
  'Tangerine',
  'Watermelon',
];

/// "Adjective Fruit" alias in the spirit of the official app.
String lsRandomAlias() =>
    '${_aliasAdjectives[_secureRandom.nextInt(_aliasAdjectives.length)]} '
    '${_aliasFruits[_secureRandom.nextInt(_aliasFruits.length)]}';
