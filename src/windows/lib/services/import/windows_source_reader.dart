import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/vault_crypto.dart';

enum SourceFailureCode {
  unavailable,
  busy,
  changed,
  unsupported,
  unsafePath,
  cancelled,
}

final class SourceFailure implements Exception {
  const SourceFailure(this.code, [this.nativeCode]);
  final SourceFailureCode code;
  final int? nativeCode;
  @override
  String toString() => 'SourceFailure(${code.name}, $nativeCode)';
}

final class SourceCancellation {
  SourceCancellation({this.checkAccess});
  final void Function()? checkAccess;
  bool cancelled = false;
  final Set<void Function()> _listeners = {};
  void check() {
    if (cancelled) throw const SourceFailure(SourceFailureCode.cancelled);
    checkAccess?.call();
    if (cancelled) throw const SourceFailure(SourceFailureCode.cancelled);
  }

  /// Register a synchronous revocation hook; the returned callback removes it.
  void Function() onCancel(void Function() listener) {
    if (cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }
}

final class SourceSnapshot {
  const SourceSnapshot({
    required this.path,
    required this.identity,
    required this.created,
    required this.modified,
    required this.size,
    required this.fingerprint,
    required this.kind,
    required this.format,
    this.previewBytes,
  });
  final String path;
  final String? identity;
  final int created, modified, size;
  final String fingerprint, kind, format;
  final Uint8List? previewBytes;
  String get version => 'blake2b-256:$size:$fingerprint';
  String get fileName => path.replaceAll('\\', '/').split('/').last;
}

final class _Overlapped extends Struct {
  @UintPtr()
  external int internal;
  @UintPtr()
  external int internalHigh;
  @Uint32()
  external int offset;
  @Uint32()
  external int offsetHigh;
  external Pointer<Void> event;
}

/// Real Windows handle, held through the encrypted commit callback. Reads use
/// OVERLAPPED I/O so revocation can call CancelIoEx without waiting on ReadFile.
/// No original is written, copied to disk, renamed, or given different ACLs.
final class WindowsSourceReader {
  static const blockSize = 1024 * 1024;
  static final _k = DynamicLibrary.open('kernel32.dll');
  static final _alloc = _k
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  static final _free = _k
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  static final _open = _shim
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Uint16>,
          Uint32,
          Uint32,
          Uint32,
          Pointer<Uint32>,
        ),
        Pointer<Void> Function(Pointer<Uint16>, int, int, int, Pointer<Uint32>)
      >('epa_open');
  static final _close = _k
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  static final _info = _k
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('GetFileInformationByHandleEx');
  static final _error = _k.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
    isLeaf: true,
  );
  static final _finalPath = _k
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Uint16>, Uint32, Uint32),
        int Function(Pointer<Void>, Pointer<Uint16>, int, int)
      >('GetFinalPathNameByHandleW');
  static final _drive = _k
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetDriveTypeW');
  static final _attributes = _k
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetFileAttributesW');
  static String? _testLibrary;
  static void setTestLibrary(String path) {
    assert(() {
      _testLibrary = path;
      return true;
    }());
  }

  static final _shim = DynamicLibrary.open(
    _testLibrary ??
        '${File(Platform.resolvedExecutable).parent.path}/epa_source_reader.dll',
  );
  static final _read = _shim
      .lookupFunction<
        Uint32 Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<_Overlapped>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<_Overlapped>,
        )
      >('epa_read_start');
  static final _move = _shim
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Uint16>),
        int Function(Pointer<Void>, Pointer<Uint16>)
      >('epa_move_to_recovery');
  static final _result = _shim
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<_Overlapped>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<_Overlapped>, Pointer<Uint32>)
      >('epa_read_result');
  static final _cancel = _k
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_Overlapped>),
        int Function(Pointer<Void>, Pointer<_Overlapped>)
      >('CancelIoEx');
  static final _event = _k
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Int32, Int32, Pointer<Uint16>),
        Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Uint16>)
      >('CreateEventW');

  static Pointer<T> _memory<T extends NativeType>(int size) {
    final p = _alloc(0x40, size);
    if (p == nullptr) throw const SourceFailure(SourceFailureCode.unavailable);
    return p.cast<T>();
  }

  static T _wide<T>(String s, T Function(Pointer<Uint16>) use) {
    final p = _memory<Uint16>((s.length + 1) * 2);
    try {
      p.asTypedList(s.length).setAll(0, s.codeUnits);
      return use(p);
    } finally {
      _free(p.cast());
    }
  }

  static Never _failed([int? knownCode]) {
    final code = knownCode ?? _error();
    throw SourceFailure(
      code == 32 || code == 33
          ? SourceFailureCode.busy
          : SourceFailureCode.unavailable,
      code,
    );
  }

  static String absolute(String path) {
    final value = File(path).absolute.path.replaceAll('/', '\\');
    if (!RegExp(r'^[a-zA-Z]:\\').hasMatch(value) ||
        value.substring(2).contains(':') ||
        value.contains('\u0000') ||
        value.split('\\').any((s) => s == '.' || s == '..')) {
      throw const SourceFailure(SourceFailureCode.unsafePath);
    }
    return value.length > 3 ? value.replaceAll(RegExp(r'\\+$'), '') : value;
  }

  static String _path(Pointer<Void> h) {
    final p = _memory<Uint16>(32768 * 2);
    try {
      final n = _finalPath(h, p, 32768, 0);
      if (n == 0 || n >= 32768) _failed();
      var s = String.fromCharCodes(p.asTypedList(n));
      if (s.startsWith('\\\\?\\')) s = s.substring(4);
      return s;
    } finally {
      _free(p.cast());
    }
  }

  static Pointer<Void> _handle(
    String path, {
    required bool directory,
    bool allowMove = false,
  }) => _wide('\\\\?\\$path', (p) {
    final attr = _attributes(p);
    if (attr == 0xffffffff) _failed();
    // Reparse points and offline/recall entries must not trigger outside reads.
    if (attr & (0x400 | 0x1000 | 0x40000 | 0x400000) != 0) {
      throw const SourceFailure(SourceFailureCode.unsafePath);
    }
    final error = _memory<Uint32>(4);
    try {
      final h = _open(
        p,
        directory ? 0x80 : (0x80000000 | (allowMove ? 0x10000 : 0)),
        directory ? 3 : 1,
        directory ? 0x02200000 : 0x48200000,
        error,
      );
      if (error.value != 0) _failed(error.value);
      return h;
    } finally {
      _free(error.cast());
    }
  });
  static ({int created, int modified, int size, String? identity}) _stat(
    Pointer<Void> h, {
    bool directory = false,
  }) {
    final p = _memory<Uint8>(48);
    try {
      if (_info(h, 0, p.cast(), 40) == 0) _failed();
      final b = ByteData.sublistView(p.asTypedList(48));
      final created = b.getInt64(0, Endian.little);
      final modified = b.getInt64(8, Endian.little);
      final attrs = b.getUint32(32, Endian.little);
      if (attrs & (0x400 | 0x1000 | 0x40000 | 0x400000) != 0 ||
          ((attrs & 0x10 != 0) != directory)) {
        throw const SourceFailure(SourceFailureCode.unsafePath);
      }
      if (_info(h, 1, p.cast(), 24) == 0) _failed();
      final size = b.getInt64(8, Endian.little);
      String? identity;
      if (_info(h, 18, p.cast(), 24) != 0) {
        identity = p
            .asTypedList(24)
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        if (created <= 0 || p.asTypedList(24).skip(8).every((b) => b == 0)) {
          identity = null;
        }
      }
      return (
        created: created,
        modified: modified,
        size: size,
        identity: identity,
      );
    } finally {
      _free(p.cast());
    }
  }

  /// Guard all ancestors against replacement; validate every opened handle.
  static List<Pointer<Void>> _ancestors(String path) {
    if (!Platform.isWindows)
      throw const SourceFailure(SourceFailureCode.unavailable);
    final type = _wide(path.substring(0, 3), _drive);
    if (type != 2 && type != 3)
      throw const SourceFailure(SourceFailureCode.unsafePath);
    final handles = <Pointer<Void>>[];
    try {
      final parts = path.substring(3).split('\\');
      var current = path.substring(0, 3);
      final root = _handle(current, directory: true);
      handles.add(root);
      _stat(root, directory: true);
      for (var i = 0; i < parts.length - 1; i++) {
        current = current.endsWith('\\')
            ? '$current${parts[i]}'
            : '$current\\${parts[i]}';
        final h = _handle(current, directory: true);
        handles.add(h);
        _stat(h, directory: true);
      }
      return handles;
    } catch (_) {
      for (final h in handles.reversed) {
        _close(h);
      }
      rethrow;
    }
  }

  static String validateDirectory(String path) {
    final full = absolute(path);
    final guards = _ancestors(
      '${full.endsWith('\\') ? full : '$full\\'}.epa-probe',
    );
    try {
      return _path(guards.last);
    } finally {
      for (final h in guards.reversed) {
        _close(h);
      }
    }
  }

  static Future<T> withDirectory<T>(
    String path,
    SourceCancellation token,
    Future<T> Function(String canonical) action,
  ) async {
    token.check();
    final full = absolute(path);
    final guards = _ancestors(
      '${full.endsWith('\\') ? full : '$full\\'}.epa-probe',
    );
    try {
      token.check();
      return await action(_path(guards.last));
    } finally {
      for (final h in guards.reversed) {
        _close(h);
      }
    }
  }

  Future<T> withSnapshot<T>(
    String path,
    String root,
    SourceCancellation token,
    FutureOr<T> Function(SourceSnapshot) consume, {
    void Function(int)? onProgress,
    FutureOr<void> Function(int size)? onOpen,
    FutureOr<void> Function(Uint8List borrowedBytes)? onBlock,
    int captureLimit = 0,
    String? moveTo,
  }) async {
    token.check();
    final crypto = await VaultCrypto.load();
    token.check();
    final full = absolute(path);
    final rootPath = absolute(root);
    if (!full.startsWith(rootPath.endsWith('\\') ? rootPath : '$rootPath\\')) {
      throw const SourceFailure(SourceFailureCode.unsafePath);
    }
    final guards = _ancestors(full);
    Pointer<Void> h = nullptr;
    Pointer<Uint8> buffer = nullptr;
    Pointer<Uint32> count = nullptr;
    Pointer<_Overlapped> overlap = nullptr;
    Pointer<Void> event = nullptr;
    final hasher = crypto.contentHasher();
    var hashClosed = false;
    Uint8List? captured;
    var captureDelivered = false;
    void revoke() {
      if (h != nullptr) _cancel(h, nullptr);
    }

    try {
      h = _handle(full, directory: false, allowMove: moveTo != null);
      final before = _stat(h);
      final actual = _path(h);
      if (actual != full || before.size <= 0) {
        throw SourceFailure(
          before.size <= 0
              ? SourceFailureCode.changed
              : SourceFailureCode.unsafePath,
        );
      }
      buffer = _memory<Uint8>(blockSize);
      count = _memory<Uint32>(4);
      overlap = _memory<_Overlapped>(sizeOf<_Overlapped>());
      event = _event(nullptr, 1, 0, nullptr);
      if (event == nullptr) _failed();
      overlap.ref.event = event;
      token._listeners.add(revoke);
      token.check();
      await onOpen?.call(before.size);
      token.check();
      var offset = 0;
      Uint8List header = Uint8List(0);
      captured = captureLimit > 0 && before.size <= captureLimit
          ? Uint8List(before.size)
          : null;
      while (true) {
        token.check();
        overlap.ref.offset = offset & 0xffffffff;
        overlap.ref.offsetHigh = offset >> 32;
        count.value = 0;
        final started = _read(h, buffer, blockSize, count, overlap);
        if (started != 0) {
          final code = started;
          if (code == 38) break;
          if (code != 997) _failed(code);
          // Do not free the buffer/OVERLAPPED until cancellation completes.
          while (true) {
            final resultError = _result(h, overlap, count);
            if (resultError == 0) break;
            if (resultError == 38) {
              count.value = 0;
              break;
            }
            if (resultError == 995)
              throw const SourceFailure(SourceFailureCode.cancelled);
            if (resultError != 996) _failed(resultError);
            if (token.cancelled) revoke();
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }
        token.check();
        final length = count.value;
        if (length == 0) break;
        final block = buffer.asTypedList(length);
        if (offset == 0) header = Uint8List.fromList(block.take(4096).toList());
        hasher.add(block);
        // Borrowed native bytes stay valid only until this callback completes.
        // The immutable handle remains held through all encryption and final
        // snapshot checks; callers must not keep the native view.
        await onBlock?.call(block);
        token.check();
        if (captured != null) {
          if (offset + length > captured.length) {
            throw const SourceFailure(SourceFailureCode.changed);
          }
          captured.setRange(offset, offset + length, block);
        }
        offset += length;
        onProgress?.call(offset);
        await Future<void>.delayed(Duration.zero);
      }
      token.check();
      final after = _stat(h);
      if (before != after || offset != before.size)
        throw const SourceFailure(SourceFailureCode.changed);
      final digest = await hasher.close();
      hashClosed = true;
      token.check();
      final format = identify(header);
      if (format == null)
        throw const SourceFailure(SourceFailureCode.unsupported);
      final value = await consume(
        SourceSnapshot(
          path: actual,
          identity: before.identity,
          created: before.created,
          modified: before.modified,
          size: offset,
          fingerprint: digest
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join(),
          kind: format.$1,
          format: format.$2,
          previewBytes: captured,
        ),
      );
      if (moveTo != null) {
        token.check();
        final destination = absolute(moveTo);
        if (destination.substring(0, 3).toLowerCase() !=
            full.substring(0, 3).toLowerCase()) {
          throw const SourceFailure(SourceFailureCode.unsafePath);
        }
        final destinationGuards = _ancestors(destination);
        try {
          token.check();
          final error = _wide('\\\\?\\$destination', (p) => _move(h, p));
          if (error != 0) _failed(error);
          if (_path(h) != destination)
            throw const SourceFailure(SourceFailureCode.changed);
        } finally {
          for (final guard in destinationGuards.reversed) {
            _close(guard);
          }
        }
      }
      captureDelivered = true;
      return value;
    } finally {
      if (!captureDelivered) captured?.fillRange(0, captured.length, 0);
      token._listeners.remove(revoke);
      if (!hashClosed) await hasher.close();
      if (buffer != nullptr) {
        buffer.asTypedList(blockSize).fillRange(0, blockSize, 0);
        _free(buffer.cast());
      }
      if (count != nullptr) _free(count.cast());
      if (overlap != nullptr) _free(overlap.cast());
      if (event != nullptr) _close(event);
      if (h != nullptr) _close(h);
      for (final guard in guards.reversed) {
        _close(guard);
      }
    }
  }

  static (String, String)? identify(Uint8List h) {
    bool starts(List<int> signature) =>
        h.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => h[i] == signature[i],
        ).every((v) => v);
    final text = latin1.decode(h, allowInvalid: true);
    if (starts([0xff, 0xd8, 0xff])) return ('photo', 'JPEG');
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return ('photo', 'PNG');
    if (text.startsWith('GIF87a') || text.startsWith('GIF89a'))
      return ('photo', 'GIF');
    if (text.startsWith('BM')) return ('photo', 'BMP');
    if (starts([73, 73, 42, 0]) || starts([77, 77, 0, 42]))
      return ('photo', 'TIFF');
    if (text.startsWith('RIFF') && text.length >= 12) {
      if (text.substring(8, 12) == 'WEBP') return ('photo', 'WebP');
      if (text.substring(8, 12) == 'AVI ') return ('video', 'AVI');
    }
    if (starts([0x1a, 0x45, 0xdf, 0xa3])) return ('video', 'Matroska/WebM');
    if (text.length >= 12 && text.substring(4, 8) == 'ftyp') {
      final brands = text.substring(8, text.length < 64 ? text.length : 64);
      if (RegExp('heic|heix|hevc|hevx|mif1|msf1|avif|avis').hasMatch(brands))
        return ('photo', 'HEIF/AVIF');
      return ('video', 'MP4/MOV');
    }
    if (text.length >= 8 &&
        {'moov', 'mdat', 'wide'}.contains(text.substring(4, 8)))
      return ('video', 'QuickTime');
    return null;
  }
}
