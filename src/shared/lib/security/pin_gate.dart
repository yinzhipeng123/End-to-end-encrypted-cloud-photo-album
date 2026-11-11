import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';

/// PIN verifier and durable attempt reservations. Caller must additionally
/// enforce the photo-password deadline; a correct PIN does not yield vault keys.
final class PinGate {
  PinGate(this._store, Uint8List binding)
    : _binding = Uint8List.fromList(binding);
  final ProtectedRecordStore _store;
  final Uint8List _binding;
  bool _busy = false;
  int _revision = 0;

  void revoke() => _revision++;

  static void validate(String pin) {
    if (!RegExp(r'^[0-9]{4}$').hasMatch(pin)) {
      throw const SecurityFailure(SecurityFailureCode.invalidPin);
    }
  }

  /// Only the access coordinator may call this after a fresh photo-password
  /// authentication. This low-level operation itself grants no vault access.
  Future<void> configure(String pin) async {
    validate(pin);
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    final revision = ++_revision;
    Uint8List? record;
    try {
      final crypto = await VaultCrypto.load();
      _requireCurrent(revision);
      final key = crypto.randomKey();
      final salt = crypto.randomBytes(16);
      try {
        record = Uint8List(88)..setRange(0, 8, ascii.encode('EPAPIN01'));
        key.runUnlockedSync((bytes) => record!.setRange(8, 40, bytes));
        record.setRange(40, 56, salt);
        record.setRange(56, 88, crypto.pinTag(key, _message(salt, pin)));
        await _store.write('pin', record, _binding);
        _requireCurrent(revision);
        await _writeRetry(const PinRetryState(0, 0));
        _requireCurrent(revision);
      } finally {
        key.dispose();
      }
    } finally {
      record?.fillRange(0, record.length, 0);
      _busy = false;
    }
  }

  Future<PinRetryState> retryState() async {
    final bytes = await _readVerifierMaterial('pin-retry');
    if (bytes == null)
      throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
    try {
      if (bytes.length != 20 ||
          ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != 'EPAPRT01') {
        throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
      }
      final data = ByteData.sublistView(bytes);
      final attempts = data.getUint32(8, Endian.little);
      final retryAt = data.getInt64(12, Endian.little);
      if (attempts > 10 || retryAt < 0)
        throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
      return PinRetryState(attempts, retryAt);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> verify(String pin, int nowUtcMillis) async {
    validate(pin);
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    final revision = _revision;
    Uint8List? record;
    try {
      final retry = await retryState();
      _requireCurrent(revision);
      if (retry.attempts >= 10)
        throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
      if (nowUtcMillis < retry.retryAtUtcMillis)
        throw const SecurityFailure(SecurityFailureCode.retryLater);
      record = await _readVerifierMaterial('pin');
      if (record == null ||
          record.length != 88 ||
          ascii.decode(record.sublist(0, 8), allowInvalid: true) !=
              'EPAPIN01') {
        throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
      }
      _requireCurrent(revision);
      // Commit a reservation BEFORE comparing. A crash cannot buy a free guess.
      final attempts = retry.attempts + 1;
      final seconds = attempts >= 5 && attempts < 10
          ? 30 * (1 << (attempts - 5))
          : 0;
      await _writeRetry(
        PinRetryState(
          attempts,
          seconds == 0 ? 0 : nowUtcMillis + seconds * 1000,
        ),
      );
      _requireCurrent(revision);
      final crypto = await VaultCrypto.load();
      _requireCurrent(revision);
      final key = crypto.protect(Uint8List.sublistView(record, 8, 40));
      try {
        final tag = crypto.pinTag(
          key,
          _message(Uint8List.sublistView(record, 40, 56), pin),
        );
        final correct = crypto.sameBytes(
          tag,
          Uint8List.sublistView(record, 56, 88),
        );
        tag.fillRange(0, tag.length, 0);
        if (!correct) {
          throw SecurityFailure(
            attempts >= 10
                ? SecurityFailureCode.photoPasswordRequired
                : SecurityFailureCode.authenticationFailed,
          );
        }
      } finally {
        key.dispose();
      }
      await _writeRetry(const PinRetryState(0, 0));
      _requireCurrent(revision);
    } finally {
      record?.fillRange(0, record.length, 0);
      _busy = false;
    }
  }

  Future<void> clearFailuresAfterPhotoAuthentication() async {
    // A partial initialization or lost DPAPI record must not publish a fresh
    // deadline and send the user to a PIN that no longer has a verifier.
    // Only the existing explicit photo-password + new-PIN flow can replace it.
    Uint8List? record;
    try {
      record = await _store.read('pin', _binding);
      if (record == null ||
          record.length != 88 ||
          ascii.decode(record.sublist(0, 8), allowInvalid: true) !=
              'EPAPIN01') {
        throw const SecurityFailure(SecurityFailureCode.pinSetupRequired);
      }
    } on SecurityFailure catch (error) {
      if (error.code == SecurityFailureCode.authenticationFailed ||
          error.code == SecurityFailureCode.invalidLength ||
          error.code == SecurityFailureCode.unsupportedFormat) {
        throw const SecurityFailure(SecurityFailureCode.pinSetupRequired);
      }
      rethrow;
    } finally {
      record?.fillRange(0, record.length, 0);
    }
    await _writeRetry(const PinRetryState(0, 0));
  }

  Future<Uint8List?> _readVerifierMaterial(String name) async {
    try {
      return await _store.read(name, _binding);
    } on SecurityFailure {
      // A damaged DPAPI record must not be mistaken for a wrong PIN while a
      // background key session remains alive.
      throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
    }
  }

  Uint8List _message(Uint8List salt, String pin) => Uint8List.fromList([
    ...ascii.encode('EPA/pin/v1\x00'),
    ..._binding,
    ...salt,
    ...ascii.encode(pin),
  ]);

  Future<void> _writeRetry(PinRetryState state) {
    final bytes = Uint8List(20)..setRange(0, 8, ascii.encode('EPAPRT01'));
    final data = ByteData.sublistView(bytes);
    data.setUint32(8, state.attempts, Endian.little);
    data.setInt64(12, state.retryAtUtcMillis, Endian.little);
    return _store.write('pin-retry', bytes, _binding);
  }

  void _requireCurrent(int revision) {
    if (_revision != revision)
      throw const SecurityFailure(SecurityFailureCode.cancelled);
  }
}

final class PinRetryState {
  const PinRetryState(this.attempts, this.retryAtUtcMillis);
  final int attempts;
  final int retryAtUtcMillis;
}
