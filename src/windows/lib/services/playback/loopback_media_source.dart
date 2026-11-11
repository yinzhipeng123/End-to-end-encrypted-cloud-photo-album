import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

/// WRP-1: one authenticated IPv4 loopback resource for one revocable view.
/// No filesystem routes, redirects, proxy, logging, or plaintext disk writes.
final class LoopbackMediaSource {
  LoopbackMediaSource._(
    this._server,
    this._crypto,
    this._secret,
    this._path,
    this.length,
    this._view,
    this._read,
    this._onFailure,
  ) {
    _removeCancel = _view.onCancel(() => unawaited(close()));
    _server.autoCompress = false;
    _server.idleTimeout = const Duration(seconds: 15);
    _server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) => _fail(),
    );
  }
  static Future<LoopbackMediaSource> open({
    required int length,
    required SourceCancellation view,
    required Future<Uint8List> Function(int block, SourceCancellation request)
    read,
    required void Function() onFailure,
  }) async {
    view.check();
    final crypto = await VaultCrypto.load();
    view.check();
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    try {
      view.check();
      return LoopbackMediaSource._(
        server,
        crypto,
        crypto.randomBytes(32),
        '/${SyncFormat.hex(crypto.randomBytes(16))}',
        length,
        view,
        read,
        onFailure,
      );
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  final HttpServer _server;
  final VaultCrypto _crypto;
  final Uint8List _secret;
  final String _path;
  final int length;
  final SourceCancellation _view;
  final Future<Uint8List> Function(int, SourceCancellation) _read;
  final void Function() _onFailure;
  void Function()? _removeCancel;
  SourceCancellation? _active;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  String get location => 'http://127.0.0.1:${_server.port}$_path';
  Map<String, String> get headers {
    _view.check();
    if (_closed) throw const SourceFailure(SourceFailureCode.cancelled);
    return {'Authorization': 'Bearer ${base64UrlEncode(_secret)}'};
  }

  bool _authorized(HttpRequest request) {
    if (_closed ||
        request.connectionInfo?.remoteAddress.isLoopback != true ||
        request.headers['host']?.length != 1 ||
        request.headers.value('host') != '127.0.0.1:${_server.port}' ||
        request.uri.toString() != _path ||
        request.headers['origin'] != null ||
        request.headers['authorization']?.length != 1 ||
        request.contentLength > 0 ||
        request.headers['transfer-encoding'] != null)
      return false;
    final header = request.headers.value('authorization')!;
    if (!header.startsWith('Bearer ') || header.length > 80) return false;
    Uint8List? supplied;
    try {
      supplied = base64Url.decode(header.substring(7));
      return supplied.length == 32 && _crypto.sameBytes(supplied, _secret);
    } catch (_) {
      return false;
    } finally {
      supplied?.fillRange(0, supplied.length, 0);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    SourceCancellation? cancellation;
    try {
      if (!_authorized(request)) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      _view.check();
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('Allow', 'GET, HEAD');
        await response.close();
        return;
      }
      final ranges = request.headers['range'];
      final range = ranges == null
          ? (0, length - 1)
          : ranges.length == 1
          ? _range(ranges.single, length)
          : null;
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */$length');
        await response.close();
        return;
      }
      response.statusCode = ranges == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.contentType = ContentType('application', 'octet-stream');
      response.contentLength = range.$2 - range.$1 + 1;
      if (ranges != null)
        response.headers.set(
          'Content-Range',
          'bytes ${range.$1}-${range.$2}/$length',
        );
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      // A newer seek cancels the previous response, then waits for its cleanup.
      _active?.cancel();
      final token = SourceCancellation(checkAccess: _view.check);
      cancellation = token;
      _active = token;
      final previous = _tail;
      final complete = Completer<void>();
      _tail = complete.future;
      final remove = _view.onCancel(token.cancel);
      unawaited(
        response.done.then<void>(
          (_) => token.cancel(),
          onError: (Object _) => token.cancel(),
        ),
      );
      try {
        await previous;
        token.check();
        for (var offset = range.$1; offset <= range.$2;) {
          token.check();
          final block = offset ~/ SyncFormat.chunkBytes;
          // On timeout revoke the request; clean any late returned plaintext.
          final bytes = await _read(block, token)
              .then((value) {
                if (token.cancelled || _closed) {
                  value.fillRange(0, value.length, 0);
                  throw const SourceFailure(SourceFailureCode.cancelled);
                }
                return value;
              })
              .timeout(
                const Duration(seconds: 60),
                onTimeout: () {
                  if (!token.cancelled) _fail();
                  token.cancel();
                  throw TimeoutException('media read');
                },
              );
          try {
            token.check();
            final start = offset % SyncFormat.chunkBytes;
            final end = (range.$2 - block * SyncFormat.chunkBytes + 1).clamp(
              0,
              bytes.length,
            );
            if (start >= end)
              throw const SourceFailure(SourceFailureCode.changed);
            response.add(Uint8List.sublistView(bytes, start, end));
            await response.flush().timeout(const Duration(seconds: 15));
            token.check();
            offset += end - start;
          } finally {
            bytes.fillRange(0, bytes.length, 0);
          }
        }
        await response.close().timeout(const Duration(seconds: 15));
      } catch (_) {
        if (!token.cancelled && !_closed) _fail();
        rethrow;
      } finally {
        token.cancel();
        remove();
        if (identical(_active, token)) _active = null;
        complete.complete();
      }
    } catch (_) {
      final wasCancelled = cancellation?.cancelled == true;
      cancellation?.cancel();
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {}
      if (!_closed && !wasCancelled) _fail();
    }
  }

  static (int, int)? _range(String text, int length) {
    if (text.length > 80 || length <= 0) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(text);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) return null;
    if (match[1]!.isEmpty) {
      final suffix = int.tryParse(match[2]!);
      if (suffix == null || suffix <= 0) return null;
      return (suffix >= length ? 0 : length - suffix, length - 1);
    }
    final start = int.tryParse(match[1]!);
    final end = match[2]!.isEmpty ? length - 1 : int.tryParse(match[2]!);
    if (start == null || end == null || start >= length || end < start)
      return null;
    return (start, end.clamp(0, length - 1));
  }

  void _fail() {
    if (_closed) return;
    _onFailure();
    unawaited(close());
  }

  Future<void> close() {
    if (_closed) return _closing ?? Future.value();
    _closed = true;
    _removeCancel?.call();
    _active?.cancel();
    _secret.fillRange(0, _secret.length, 0);
    return _closing = _server.close(force: true).then<void>((_) {});
  }
}
