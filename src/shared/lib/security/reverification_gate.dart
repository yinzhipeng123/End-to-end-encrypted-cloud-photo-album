import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/pin_gate.dart';
import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';

abstract interface class SecurityClock {
  int utcMilliseconds();
  int monotonicMilliseconds();
}

/// Durable deadline, clock checks and real credential access. UI, lifecycle
/// callbacks and repository cancellation subscribe to [onRevoke] in task 2.5.
final class ReverificationGate {
  ReverificationGate({
    required this.store,
    required this.credentials,
    required this.pinGate,
    required this.clock,
    required Uint8List binding,
    required Uint8List vaultId,
    required this.wrappingGeneration,
  }) : _binding = Uint8List.fromList(binding),
       _vaultId = Uint8List.fromList(vaultId);

  static const durationMillis = 259200000;
  static const toleranceMillis = 60000;
  final ProtectedRecordStore store;
  final VaultCredentials credentials;
  final PinGate pinGate;
  final SecurityClock clock;
  final Uint8List _binding;
  final Uint8List _vaultId;
  int wrappingGeneration;
  void Function()? onRevoke;
  ReverificationState? _state;
  VaultCredentialSession? _session;
  int? _anchorUtc;
  int? _anchorMonotonic;
  int _revision = 0;
  bool _busy = false;
  bool _forcedPhoto = true;
  Future<void> _stateTail = Future<void>.value();

  ReverificationState? get state => _state;
  bool get requiresPhotoPassword {
    if (!_timeValid()) {
      _forcedPhoto = true;
      if (_session != null) lock();
    }
    return _forcedPhoto;
  }

  VaultCredentialSession get session {
    if (!_timeValid()) _forcedPhoto = true;
    if (_session == null ||
        _session!.isClosed ||
        !_timeValid() ||
        _forcedPhoto) {
      lock();
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    return _session!;
  }

  Future<void> load() async {
    lock();
    try {
      final bytes = await store.read('access-state', _binding);
      if (bytes == null) {
        _state = null;
        _forcedPhoto = true;
        return;
      }
      try {
        _state = ReverificationState.parse(bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      _anchorUtc = clock.utcMilliseconds();
      _anchorMonotonic = clock.monotonicMilliseconds();
      _forcedPhoto = !_timeValid();
      if (await store.read('repository-password-required', _binding) != null) {
        _forcedPhoto = true;
      }
      if (!_forcedPhoto) await checkpoint();
    } on SecurityFailure {
      _state = null;
      _forcedPhoto = true;
    }
  }

  void lock() {
    _revision++;
    credentials.revoke();
    pinGate.revoke();
    _session = null;
    onRevoke?.call();
  }

  /// Revoke pending UI PIN checks without ending the approved background
  /// lifetime. This never grants access or refreshes the photo deadline.
  void lockInterface() {
    _revision++;
    pinGate.revoke();
  }

  /// Re-open only the interface of an already authenticated background session.
  /// Ordinary failed PIN attempts do not terminate background work. Forced
  /// photo authentication, damaged retry state and expiry still revoke it.
  Future<void> verifyInterfacePin(String pin) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    final revision = _revision;
    try {
      session;
      await checkpoint();
      _requireCurrent(revision);
      await pinGate.verify(pin, clock.utcMilliseconds());
      _requireCurrent(revision);
      await checkpoint();
      _requireCurrent(revision);
      session;
    } on SecurityFailure catch (error) {
      if (!isOrdinaryPinFailure(error)) {
        _forcedPhoto = true;
        lock();
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  static bool isOrdinaryPinFailure(SecurityFailure error) =>
      error.code == SecurityFailureCode.invalidPin ||
      error.code == SecurityFailureCode.authenticationFailed ||
      error.code == SecurityFailureCode.retryLater ||
      error.code == SecurityFailureCode.cancelled;

  Future<void> requirePhotoAuthentication() async {
    _forcedPhoto = true;
    try {
      await checkpoint();
    } on SecurityFailure catch (error) {
      if (error.code != SecurityFailureCode.photoPasswordRequired) rethrow;
    }
  }

  bool _timeValid() {
    final saved = _state;
    if (saved == null ||
        saved.generation != wrappingGeneration ||
        saved.anomaly)
      return false;
    final now = clock.utcMilliseconds();
    final ticks = clock.monotonicMilliseconds();
    if (now < 0 ||
        ticks < 0 ||
        now >= saved.expiresAt ||
        saved.maximumUtc >= saved.expiresAt ||
        now < saved.maximumUtc - toleranceMillis)
      return false;
    final anchorUtc = _anchorUtc;
    final anchorTicks = _anchorMonotonic;
    if (anchorUtc == null ||
        anchorTicks == null ||
        ticks < anchorTicks ||
        ((now - anchorUtc) - (ticks - anchorTicks)).abs() > toleranceMillis)
      return false;
    return true;
  }

  /// Called before sensitive work and periodically while the App is active.
  Future<void> checkpoint() => _serializeState(_checkpoint);

  Future<void> _checkpoint() async {
    final saved = _state;
    if (!_timeValid() || _forcedPhoto) {
      _forcedPhoto = true;
      lock();
      if (saved != null) {
        _state = saved.withMaximum(saved.maximumUtc, anomaly: true);
        await store.write('access-state', _state!.encode(), _binding);
      }
      await store.remove('auxiliary');
      throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
    }
    final now = clock.utcMilliseconds();
    if (saved != null && now > saved.maximumUtc) {
      _state = saved.withMaximum(now);
      try {
        await store.write('access-state', _state!.encode(), _binding);
      } catch (_) {
        _forcedPhoto = true;
        lock();
        rethrow;
      }
    }
  }

  /// The supplied session must come from actual photo-password authentication.
  /// This starts the period but does not itself skip the ordinary PIN gate.
  Future<void> recordPhotoAuthentication(
    VaultCredentialSession authenticated,
  ) => _serializeState(() => _recordPhotoAuthentication(authenticated));

  Future<void> _recordPhotoAuthentication(
    VaultCredentialSession authenticated,
  ) async {
    if (!authenticated.authenticatedByPhotoPassword ||
        !_same(authenticated.vaultId, _vaultId) ||
        authenticated.generation != wrappingGeneration) {
      throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
    }
    final revision = _revision;
    final now = clock.utcMilliseconds();
    final ticks = clock.monotonicMilliseconds();
    if (now <= 0 || ticks < 0) {
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    }
    authenticated.consumePhotoAuthenticationProof();
    final saved = ReverificationState(
      wrappingGeneration,
      now,
      now + durationMillis,
      now,
      false,
    );
    try {
      // Save auxiliary first, then publish the matching deadline. An old state
      // cannot open the new binding if publication fails halfway through.
      await authenticated.saveAuxiliary(store, _auxiliaryBinding(saved));
      _requireCurrent(revision);
      await store.write('access-state', saved.encode(), _binding);
      _requireCurrent(revision);
      _state = saved;
      _anchorUtc = now;
      _anchorMonotonic = ticks;
      _forcedPhoto = false;
    } catch (_) {
      _forcedPhoto = true;
      lock();
      rethrow;
    }
  }

  Future<VaultCredentialSession> unlockWithPin(String pin) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    final revision = _revision;
    var pinVerified = false;
    try {
      await checkpoint();
      _requireCurrent(revision);
      await pinGate.verify(pin, clock.utcMilliseconds());
      pinVerified = true;
      _requireCurrent(revision);
      await checkpoint();
      _requireCurrent(revision);
      final opened = await credentials.unlockWithAuxiliary(
        store: store,
        binding: _auxiliaryBinding(_state!),
        expectedVaultId: _vaultId,
      );
      _requireCurrent(revision);
      await checkpoint();
      _requireCurrent(revision);
      _session = opened;
      return opened;
    } on SecurityFailure catch (error) {
      if (pinVerified ||
          (error.code != SecurityFailureCode.invalidPin &&
              error.code != SecurityFailureCode.authenticationFailed &&
              error.code != SecurityFailureCode.retryLater &&
              error.code != SecurityFailureCode.cancelled)) {
        _forcedPhoto = true;
      }
      // Wrong PIN never retains an earlier vault session.
      lock();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Real password service plus durable retry reservation before every KDF.
  Future<VaultCredentialSession> authenticatePhotoPassword(
    String password, {
    Uint8List? repositoryRecovery,
  }) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    lock();
    final revision = _revision;
    try {
      await _reservePasswordAttempt();
      _requireCurrent(revision);
      final authenticated = repositoryRecovery == null
          ? await credentials.unlock(
              password: password,
              expectedVaultId: _vaultId,
            )
          : await credentials.adoptRepositoryPassword(
              recovery: repositoryRecovery,
              password: password,
              expectedVaultId: _vaultId,
            );
      _requireCurrent(revision);
      wrappingGeneration = authenticated.generation;
      await store.write('photo-retry', _retryBytes(0, 0), _binding);
      _requireCurrent(revision);
      return authenticated;
    } finally {
      _busy = false;
    }
  }

  Future<void> _reservePasswordAttempt() async {
    final now = clock.utcMilliseconds();
    var count = 0;
    var retryAt = 0;
    Uint8List? bytes;
    try {
      bytes = await store.read('photo-retry', _binding);
      if (bytes != null &&
          bytes.length == 20 &&
          ascii.decode(bytes.sublist(0, 8), allowInvalid: true) == 'EPAPWD01') {
        final data = ByteData.sublistView(bytes);
        count = data.getUint32(8, Endian.little);
        retryAt = data.getInt64(12, Endian.little);
        if (count > 64 || retryAt < 0) {
          count = 0;
          retryAt = 0;
        }
      }
    } on SecurityFailure catch (error) {
      // Lost/corrupt platform state permits only a real photo-password attempt,
      // never a PIN reset or deadline extension. Available limits are retained.
      if (error.code != SecurityFailureCode.authenticationFailed) rethrow;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
    if (now < retryAt)
      throw const SecurityFailure(SecurityFailureCode.retryLater);
    count = (count + 1).clamp(1, 64);
    final seconds = count < 5
        ? 0
        : count >= 10
        ? 900
        : 30 * (1 << (count - 5));
    await store.write(
      'photo-retry',
      _retryBytes(count, seconds == 0 ? 0 : now + seconds * 1000),
      _binding,
    );
  }

  /// Only callable from an already unlocked session (including its PIN gate).
  /// Password changes share the durable photo-password retry budget.
  Future<void> changePhotoPassword({
    required String oldPassword,
    required String newPassword,
    required String confirmation,
  }) async {
    session;
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    lock();
    final revision = _revision;
    try {
      await _reservePasswordAttempt();
      _requireCurrent(revision);
      final changed = await credentials.changePassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
        confirmation: confirmation,
        expectedVaultId: _vaultId,
      );
      _requireCurrent(revision);
      wrappingGeneration = changed.generation;
      await store.write('photo-retry', _retryBytes(0, 0), _binding);
      _requireCurrent(revision);
      await recordPhotoAuthentication(changed);
      _requireCurrent(revision);
    } finally {
      _busy = false;
      lock();
    }
  }

  Uint8List _retryBytes(int count, int retryAt) {
    final bytes = Uint8List(20)..setRange(0, 8, ascii.encode('EPAPWD01'));
    final data = ByteData.sublistView(bytes);
    data.setUint32(8, count, Endian.little);
    data.setInt64(12, retryAt, Endian.little);
    return bytes;
  }

  Uint8List _auxiliaryBinding(ReverificationState state) {
    final suffix = ByteData(24)
      ..setInt64(0, state.generation, Endian.little)
      ..setInt64(8, state.lastPhotoAuthentication, Endian.little)
      ..setInt64(16, state.expiresAt, Endian.little);
    return Uint8List.fromList([
      ..._binding,
      ..._vaultId,
      ...suffix.buffer.asUint8List(),
    ]);
  }

  void _requireCurrent(int revision) {
    if (_revision != revision)
      throw const SecurityFailure(SecurityFailureCode.cancelled);
  }

  bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  Future<void> _serializeState(Future<void> Function() operation) {
    final result = _stateTail.then((_) => operation());
    _stateTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}

final class ReverificationState {
  const ReverificationState(
    this.generation,
    this.lastPhotoAuthentication,
    this.expiresAt,
    this.maximumUtc,
    this.anomaly,
  );
  final int generation;
  final int lastPhotoAuthentication;
  final int expiresAt;
  final int maximumUtc;
  final bool anomaly;

  factory ReverificationState.parse(Uint8List bytes) {
    if (bytes.length != 41 ||
        ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != 'EPAGAT01' ||
        bytes[40] > 1) {
      throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
    }
    final data = ByteData.sublistView(bytes);
    final state = ReverificationState(
      data.getInt64(8, Endian.little),
      data.getInt64(16, Endian.little),
      data.getInt64(24, Endian.little),
      data.getInt64(32, Endian.little),
      bytes[40] == 1,
    );
    if (state.generation < 1 ||
        state.lastPhotoAuthentication <= 0 ||
        state.expiresAt !=
            state.lastPhotoAuthentication + ReverificationGate.durationMillis ||
        state.maximumUtc < state.lastPhotoAuthentication) {
      throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
    }
    return state;
  }

  ReverificationState withMaximum(int maximum, {bool? anomaly}) =>
      ReverificationState(
        generation,
        lastPhotoAuthentication,
        expiresAt,
        maximum,
        anomaly ?? this.anomaly,
      );

  Uint8List encode() {
    final bytes = Uint8List(41)..setRange(0, 8, ascii.encode('EPAGAT01'));
    final data = ByteData.sublistView(bytes);
    data.setInt64(8, generation, Endian.little);
    data.setInt64(16, lastPhotoAuthentication, Endian.little);
    data.setInt64(24, expiresAt, Endian.little);
    data.setInt64(32, maximumUtc, Endian.little);
    bytes[40] = anomaly ? 1 : 0;
    return bytes;
  }
}
