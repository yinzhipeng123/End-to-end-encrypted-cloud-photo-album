import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';

enum SyncFailureCode {
  format,
  integrity,
  cancelled,
  sourceChanged,
  space,
  conflict,
  notInitialized,
  wrongVault,
  repositoryPasswordRequired,
}

final class SyncFailure implements Exception {
  const SyncFailure(this.code);
  final SyncFailureCode code;
  @override
  String toString() => 'SyncFailure(${code.name})';
}

/// WSR-1 byte contract. All persisted business fields belong in authenticated
/// manifests or SQLCipher; ciphertext paths use random identifiers only.
abstract final class SyncFormat {
  static const chunkBytes = 4 * 1024 * 1024;
  static const overhead = 48;
  static const metadataBytes = 1024 * 1024;
  static const objectLimit = 50000000;
  static const pageEntries = 256;
  static const zeroId = '00000000000000000000000000000000';
  static const directory = '.encrypted-photo-app/v1';
  static const branch = 'epa-data-v1';
  static String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  static String newId(VaultCrypto crypto) => hex(crypto.randomBytes(16));
  static Uint8List id(String value) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) invalid();
    return Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);
  }

  static String objectPath(String objectId) {
    id(objectId);
    return '$directory/objects/${objectId.substring(0, 2)}/$objectId.bin';
  }

  static Never invalid() => throw const SyncFailure(SyncFailureCode.format);
  static void fields(Map<String, Object?> value, Set<String> names) {
    if (value.length != names.length || !value.keys.every(names.contains))
      invalid();
  }

  static int count(
    Object? value, {
    int minimum = 0,
    int maximum = 0x7fffffffffffffff,
  }) {
    if (value is! String || !RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(value))
      invalid();
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < minimum || parsed > maximum) invalid();
    return parsed;
  }

  static Map<String, Object?> map(Object? value) {
    if (value is! Map<String, dynamic>) invalid();
    return value;
  }

  static Uint8List resourceContext(
    String media,
    String revision,
    String resource,
  ) => Uint8List.fromList([
    ...ascii.encode('EPA/resource/v1\x00'),
    ...id(media),
    ...id(revision),
    ...id(resource),
  ]);
  static Uint8List chunkContext(int index, int count, int total, int length) {
    if (total <= 0 ||
        index < 0 ||
        count != (total + chunkBytes - 1) ~/ chunkBytes ||
        index >= count ||
        length !=
            (index == count - 1 ? total - index * chunkBytes : chunkBytes))
      invalid();
    final data = ByteData(28)
      ..setUint64(0, index, Endian.little)
      ..setUint64(8, count, Endian.little)
      ..setUint64(16, total, Endian.little)
      ..setUint32(24, length, Endian.little);
    return Uint8List.fromList([
      ...ascii.encode('EPA/chunk/v1\x00'),
      ...data.buffer.asUint8List(),
    ]);
  }

  static Uint8List metadataContext(String kind, String objectId) {
    if (!{'root', 'index', 'media', 'resource', 'page'}.contains(kind))
      invalid();
    return Uint8List.fromList([
      ...ascii.encode('EPA/metadata/v1\x00$kind'),
      ...id(objectId),
    ]);
  }

  static Uint8List pack(String magic, VaultCiphertext cipher) =>
      Uint8List.fromList([
        ...ascii.encode(magic),
        ...cipher.nonce,
        ...cipher.ciphertext,
      ]);
  static VaultCiphertext unpack(
    Uint8List bytes,
    String magic,
    int maxPlaintext,
  ) {
    if (bytes.length < overhead ||
        bytes.length > maxPlaintext + overhead ||
        ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != magic)
      invalid();
    return VaultCiphertext(
      nonce: Uint8List.sublistView(bytes, 8, 32),
      ciphertext: Uint8List.sublistView(bytes, 32),
    );
  }

  static Future<String> digest(VaultCrypto crypto, Uint8List bytes) async {
    final hash = crypto.contentHasher()..add(bytes);
    return hex(await hash.close());
  }

  // Only null/bool/string/list/object. Decimal counts are strings on the wire.
  static Object? _canonical(Object? value, int depth) {
    if (depth > 32) invalid();
    if (value == null || value is bool) return value;
    if (value is String) {
      // UTF-16 lone surrogates must not be silently replaced by UTF-8 encoding.
      for (var i = 0; i < value.length; i++) {
        final u = value.codeUnitAt(i);
        if (u >= 0xd800 && u <= 0xdbff) {
          if (++i == value.length) invalid();
          final low = value.codeUnitAt(i);
          if (low < 0xdc00 || low > 0xdfff) invalid();
        } else if (u >= 0xdc00 && u <= 0xdfff) {
          invalid();
        }
      }
      return value;
    }
    if (value is List)
      return value.map((v) => _canonical(v, depth + 1)).toList();
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()
        ..sort((a, b) {
          final x = a.runes.toList(), y = b.runes.toList();
          for (var i = 0; i < x.length && i < y.length; i++) {
            if (x[i] != y[i]) return x[i].compareTo(y[i]);
          }
          return x.length.compareTo(y.length);
        });
      return {
        for (final key in keys)
          _canonical(key, depth + 1) as String: _canonical(
            value[key],
            depth + 1,
          ),
      };
    }
    invalid();
  }

  static Uint8List encodeJson(Map<String, Object?> value) {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_canonical(value, 0))),
    );
    if (bytes.length > metadataBytes) invalid();
    return bytes;
  }

  static Map<String, Object?> decodeJson(Uint8List bytes) {
    if (bytes.length > metadataBytes) invalid();
    // Bound nesting before the platform JSON parser (including malformed input).
    var depth = 0, quoted = false, escaped = false;
    for (final b in bytes) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (b == 92) {
          escaped = true;
        } else if (b == 34) {
          quoted = false;
        }
      } else if (b == 34) {
        quoted = true;
      } else if (b == 123 || b == 91) {
        if (++depth > 32) invalid();
      } else if (b == 125 || b == 93) {
        if (--depth < 0) invalid();
      }
    }
    try {
      final result = map(jsonDecode(utf8.decode(bytes)));
      final canonical = encodeJson(result);
      try {
        if (canonical.length != bytes.length) invalid();
        for (var i = 0; i < bytes.length; i++) {
          if (bytes[i] != canonical[i]) invalid();
        }
      } finally {
        canonical.fillRange(0, canonical.length, 0);
      }
      return result;
    } on FormatException {
      invalid();
    }
  }

  static Uint8List encryptMetadata(
    VaultCredentialSession session,
    String kind,
    String objectId,
    Map<String, Object?> value,
  ) {
    final clear = encodeJson(value);
    try {
      return pack(
        'EPAMET01',
        session.encryptRecoveryMetadata(clear, metadataContext(kind, objectId)),
      );
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  static Map<String, Object?> decryptMetadata(
    VaultCredentialSession session,
    String kind,
    String objectId,
    Uint8List bytes,
  ) {
    final clear = session.decryptRecoveryMetadata(
      unpack(bytes, 'EPAMET01', metadataBytes),
      metadataContext(kind, objectId),
    );
    try {
      return decodeJson(clear);
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }
}

/// Streaming encryption of one immutable source version. A sink must persist
/// each ciphertext and checkpoint before returning; plaintext never accumulates
/// beyond one 4 MiB buffer. The caller owns source stability and final publication.
final class ResourceBlockEncoder {
  ResourceBlockEncoder({
    required this.resource,
    required this.totalBytes,
    required this.checkAccess,
    required this.writeBlock,
  }) {
    if (totalBytes <= 0 ||
        totalBytes > 0x7fffffffffffffff - SyncFormat.chunkBytes)
      SyncFormat.invalid();
    _buffer = Uint8List(
      totalBytes < SyncFormat.chunkBytes ? totalBytes : SyncFormat.chunkBytes,
    );
  }
  final VaultResourceSession resource;
  final int totalBytes;
  final void Function() checkAccess;
  final Future<void> Function(int index, int clearLength, Uint8List ciphertext)
  writeBlock;
  late final Uint8List _buffer;
  int _used = 0, _received = 0, _index = 0;
  bool _closed = false, _busy = false;
  int get chunkCount =>
      (totalBytes + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes;

  Future<void> add(Uint8List bytes) async {
    if (_closed || _busy) throw const SyncFailure(SyncFailureCode.cancelled);
    _busy = true;
    try {
      checkAccess();
      if (bytes.length > totalBytes - _received)
        throw const SyncFailure(SyncFailureCode.sourceChanged);
      var at = 0;
      while (at < bytes.length) {
        checkAccess();
        final amount = (_buffer.length - _used) < (bytes.length - at)
            ? _buffer.length - _used
            : bytes.length - at;
        _buffer.setRange(_used, _used + amount, bytes, at);
        _used += amount;
        at += amount;
        _received += amount;
        if (_used == _buffer.length || _received == totalBytes) {
          final clear = Uint8List.sublistView(_buffer, 0, _used);
          final encrypted = SyncFormat.pack(
            'EPABLK01',
            resource.encrypt(
              clear,
              unitContext: SyncFormat.chunkContext(
                _index,
                chunkCount,
                totalBytes,
                _used,
              ),
            ),
          );
          _buffer.fillRange(0, _buffer.length, 0);
          checkAccess();
          await writeBlock(_index, _used, encrypted);
          checkAccess();
          _index++;
          _used = 0;
        }
      }
    } catch (_) {
      close();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  void finish() {
    checkAccess();
    if (_closed ||
        _busy ||
        _received != totalBytes ||
        _used != 0 ||
        _index != chunkCount) {
      close();
      throw const SyncFailure(SyncFailureCode.sourceChanged);
    }
    close();
  }

  void close() {
    _closed = true;
    _buffer.fillRange(0, _buffer.length, 0);
  }
}

Uint8List decryptResourceBlock(
  VaultResourceSession resource,
  Uint8List bytes, {
  required int index,
  required int totalBytes,
}) {
  final count =
      (totalBytes + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes;
  final length = index == count - 1
      ? totalBytes - index * SyncFormat.chunkBytes
      : SyncFormat.chunkBytes;
  final context = SyncFormat.chunkContext(index, count, totalBytes, length);
  if (bytes.length != length + SyncFormat.overhead) SyncFormat.invalid();
  return resource.decrypt(
    SyncFormat.unpack(bytes, 'EPABLK01', SyncFormat.chunkBytes),
    unitContext: context,
  );
}
