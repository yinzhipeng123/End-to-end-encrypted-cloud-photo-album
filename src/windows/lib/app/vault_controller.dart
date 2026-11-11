import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:encrypted_photo_shared/security/pin_gate.dart';
import 'package:encrypted_photo_shared/security/photo_password.dart';
import 'package:encrypted_photo_shared/security/reverification_gate.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:encrypted_photo_app/security/windows_security_clock.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/repository_vault_recovery.dart';
import 'package:encrypted_photo_app/app/vault_location_store.dart';

enum VaultScreen { loading, setup, pin, photoPassword, library, failure }

/// The production access boundary. No media or repository simulator is used.
/// A session and a real catalog are published only after both access gates pass.
final class VaultController extends ChangeNotifier {
  VaultController(
    this.defaultDataDirectory, {
    SecurityClock? clock,
    this.automaticCheck = true,
    this.repositoryApi,
  }) : _directory = defaultDataDirectory,
       _clock = clock ?? WindowsSecurityClock(WindowsDataProtection());

  final Directory defaultDataDirectory;
  Directory _directory;
  Directory get directory => _directory;
  Directory? _selectedDirectory;
  Directory get setupDirectory => _selectedDirectory ?? directory;
  late final _locations = VaultLocationStore(defaultDataDirectory);
  bool _locationChanged = false;
  final SecurityClock _clock;
  final bool automaticCheck;

  /// Optional transport injection for isolated tests; production uses HTTPS.
  @visibleForTesting
  final GitHubApi? repositoryApi;
  final _platform = WindowsDataProtection();
  late WindowsProtectedStore _store = WindowsProtectedStore(
    directory,
    _platform,
  );
  late VaultBootstrapStore _bootstrap = VaultBootstrapStore(
    File('${directory.path}/vault.bootstrap'),
    commitReplacement: _platform.replacePrivateFile,
  );
  late VaultCredentials _credentials = VaultCredentials(_bootstrap);
  File get catalogFile => File('${directory.path}/catalog.db');
  ReverificationGate? _gate;
  LibraryCatalog? _catalog;
  LibraryCatalog? _backgroundCatalog;
  GitHubConnection? github;
  WindowsImportService? imports;
  WindowsSyncService? sync;
  LibraryOrganizationService? organization;
  RandomAccessFile? _instanceLock;
  Uint8List? _installation;
  Timer? _timer;
  bool _checking = false;
  bool _starting = false;
  bool _closed = false;
  bool _busy = false;
  int _revision = 0;
  int accessEpoch = 0;
  VaultScreen screen = VaultScreen.loading;
  String? message;
  bool repositoryPasswordRequired = false;

  bool get busy => _busy;
  int? get expiresAt => _gate?.state?.expiresAt;
  int get mediaCount => catalog.mediaCount;
  LibraryCatalog get catalog {
    if (_closed || screen != VaultScreen.library || _catalog == null) {
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    _gate!.session; // Rechecks the deadline even between periodic checkpoints.
    return _catalog!;
  }

  LibraryCatalog get _workCatalog {
    if (_closed || _backgroundCatalog == null) {
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    _gate!.session;
    return _backgroundCatalog!;
  }

  void Function() _acquireView() {
    catalog;
    final epoch = accessEpoch;
    return () {
      if (epoch != accessEpoch) {
        throw const SecurityFailure(SecurityFailureCode.cancelled);
      }
      catalog;
    };
  }

  void _openInterface(VaultCredentialSession session) {
    screen = VaultScreen.library;
    final epoch = ++accessEpoch;
    _catalog = LibraryCatalog.open(
      catalogFile,
      session,
      checkAccess: () {
        if (_closed || screen != VaultScreen.library || accessEpoch != epoch) {
          throw const SecurityFailure(SecurityFailureCode.accessDenied);
        }
        _gate!.session;
      },
    );
    organization = LibraryOrganizationService(
      imports!,
      additionalChanges: sync,
      viewCatalog: () => catalog,
    );
  }

  static Directory defaultDirectory() {
    final base = Platform.environment['LOCALAPPDATA'];
    if (!Platform.isWindows || base == null || base.isEmpty) {
      throw const SecurityFailure(SecurityFailureCode.backendUnavailable);
    }
    return Directory('$base/EncryptedPhotoApp');
  }

  Future<void> start() async {
    if (_closed || _starting || _instanceLock != null) return;
    _starting = true;
    var locationResolved = false;
    try {
      final resolved = await _locations.open();
      locationResolved = true;
      if (_closed) {
        await _locations.close();
        return;
      }
      _bindDirectory(resolved);
      await _store.initialize();
      final lockFile = File('${directory.path}/instance.lock');
      _instanceLock = await lockFile.open(mode: FileMode.append);
      if (_closed) {
        await _instanceLock!.close();
        _instanceLock = null;
        return;
      }
      _platform.validatePrivatePath(lockFile.path);
      try {
        await _instanceLock!.lock(FileLock.exclusive);
      } catch (_) {
        await _instanceLock!.close();
        _instanceLock = null;
        throw const SecurityFailure(SecurityFailureCode.busy);
      }
      final binding = Uint8List.fromList(ascii.encode('EPA/installation/v1'));
      _installation = await _store.read('installation', binding);
      if (_installation == null) {
        _installation = (await VaultCrypto.load()).randomBytes(32);
        await _store.write('installation', _installation!, binding);
      }
      if (_installation!.length != 32) {
        throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
      }
      if (!await _bootstrap.file.exists()) {
        if (await catalogFile.exists()) {
          throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
        }
        screen = VaultScreen.setup;
      } else {
        _platform.validatePrivatePath(_bootstrap.file.path);
        if (!await catalogFile.exists()) {
          throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
        }
        await _loadGate();
        screen = _gate!.requiresPhotoPassword
            ? VaultScreen.photoPassword
            : VaultScreen.pin;
      }
      if (_closed) return;
      if (automaticCheck) {
        _timer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => checkAccess(),
        );
      }
    } catch (error) {
      screen = VaultScreen.failure;
      message =
          !locationResolved &&
              !(error is SecurityFailure &&
                  error.code == SecurityFailureCode.busy)
          ? '无法读取程序的数据保存位置。目录可能不可用或定位记录损坏；未新建或覆盖照片库。'
          : describeFailure(error);
    } finally {
      _starting = false;
    }
    _notify();
  }

  void _bindDirectory(Directory value) {
    _credentials.revoke();
    _directory = value;
    _store = WindowsProtectedStore(directory, _platform);
    _bootstrap = VaultBootstrapStore(
      File('${directory.path}/vault.bootstrap'),
      commitReplacement: _platform.replacePrivateFile,
    );
    _credentials = VaultCredentials(_bootstrap);
  }

  void selectDataParent(String parent) {
    if (_closed || busy || screen != VaultScreen.setup) return;
    try {
      _selectedDirectory = _locations.candidate(parent);
      message = null;
    } catch (error) {
      message =
          error is SecurityFailure &&
              error.code == SecurityFailureCode.alreadyExists
          ? '所选位置已有 EncryptedPhotoApp 文件或文件夹，请选择其他位置；已有数据未修改。'
          : '无法使用所选位置。请选择可访问的本机文件夹，不能使用网络位置或链接目录。';
    }
    _notify();
  }

  void useDefaultDataDirectory() {
    if (_closed || busy || screen != VaultScreen.setup) return;
    _selectedDirectory = null;
    message = null;
    _notify();
  }

  Future<void> _prepareSelectedLocation(int revision) async {
    final selected = _selectedDirectory;
    if (selected == null ||
        VaultLocationStore.sameDirectory(selected, directory)) {
      return;
    }
    _locations.prepareNew(selected);
    final lockFile = File('${selected.path}/instance.lock');
    final handle = await lockFile.open(mode: FileMode.append);
    var transferred = false;
    try {
      _platform.validatePrivatePath(lockFile.path);
      await handle.lock(FileLock.exclusive);
      _requireCurrent(revision);
      await _instanceLock?.close();
      _requireCurrent(revision);
      _instanceLock = handle;
      transferred = true;
      _bindDirectory(selected);
      _locationChanged = true;
      // Persist before credentials: interrupted setup must remain discoverable,
      // and subsequent startup must fail closed instead of creating another vault.
      await _locations.save(directory);
      _requireCurrent(revision);
      _installation = (await VaultCrypto.load()).randomBytes(32);
      await _store.write(
        'installation',
        _installation!,
        Uint8List.fromList(ascii.encode('EPA/installation/v1')),
      );
      _requireCurrent(revision);
    } finally {
      if (!transferred) await handle.close();
    }
  }

  Future<void> _loadGate() async {
    final record = await _bootstrap.read();
    _gate?.onRevoke = null;
    _gate = ReverificationGate(
      store: _store,
      credentials: _credentials,
      pinGate: PinGate(_store, _installation!),
      clock: _clock,
      binding: _installation!,
      vaultId: record.vaultId,
      wrappingGeneration: record.generation,
    );
    await _gate!.load();
    repositoryPasswordRequired =
        await _store.read('repository-password-required', _installation!) !=
        null;
    _gate!.onRevoke = _hideLibrary;
  }

  Future<void> initialize({
    required String password,
    required String confirmation,
    required String pin,
    required String pinConfirmation,
  }) => _operation(() async {
    if (screen != VaultScreen.setup) {
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    _validatePinConfirmation(pin, pinConfirmation);
    final encoded = PhotoPassword.encode(password, confirmation: confirmation);
    encoded.fillRange(0, encoded.length, 0);
    final revision = _revision;
    await _prepareSelectedLocation(revision);
    _requireCurrent(revision);
    final session = await _credentials.initialize(
      password: password,
      confirmation: confirmation,
    );
    _requireCurrent(revision);
    final created = LibraryCatalog.create(catalogFile, session);
    try {
      created.verifyIntegrity();
    } finally {
      created.close();
    }
    // Loading the gate revokes sessions. Complete initialization with a fresh
    // authenticated session; no key or password is stored by this controller.
    await _loadGate();
    _requireCurrent(revision);
    final authenticated = await _gate!.authenticatePhotoPassword(password);
    _requireCurrent(revision);
    await _gate!.pinGate.configure(pin);
    _requireCurrent(revision);
    await _gate!.recordPhotoAuthentication(authenticated);
    _requireCurrent(revision);
    _gate!.lock();
    screen = VaultScreen.pin;
    message = '加密照片库已建立。请输入刚设置的四位应用锁密码。';
  });

  Future<void> unlock(String pin) => _operation(() async {
    if (screen != VaultScreen.pin) {
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    final revision = _revision;
    if (_backgroundCatalog != null) {
      await _gate!.verifyInterfacePin(pin);
      _requireCurrent(revision);
      _openInterface(_gate!.session);
      return;
    }
    final session = await _gate!.unlockWithPin(pin);
    _requireCurrent(revision);
    _platform.validatePrivatePath(catalogFile.path);
    final opened = LibraryCatalog.open(
      catalogFile,
      session,
      checkAccess: () {
        _gate!.session;
      },
    );
    try {
      opened.verifyIntegrity();
      await _gate!.checkpoint();
      _requireCurrent(revision);
      _backgroundCatalog = opened;
      github = GitHubConnection(
        api: repositoryApi,
        catalog: () => _workCatalog,
        acquireView: _acquireView,
        protectedStore: _store,
        localBinding: _installation!,
      );
      imports = WindowsImportService(
        catalog: () => _workCatalog,
        acquireView: _acquireView,
      );
      sync = WindowsSyncService(
        catalog: () => _workCatalog,
        acquireView: _acquireView,
        session: () {
          _workCatalog;
          return _gate!.session;
        },
        connection: github!,
        imports: imports!,
        directory: directory,
        onRepositoryPasswordChanged: _repositoryPasswordChanged,
      )..start();
      _openInterface(session);
      imports!.start();
    } catch (_) {
      opened.close();
      rethrow;
    }
  }, preserveBackgroundOnPinFailure: true);

  void requestPhotoPassword() {
    suspend();
    screen = VaultScreen.photoPassword;
    _notify();
  }

  void reportPlatformUnavailable() {
    if (_closed) return;
    suspend();
    message = 'Windows 安全事件监听不可用或窗口已锁定，无法解锁。';
    _notify();
  }

  Future<void> authenticatePhotoPassword(
    String password, {
    String? newPin,
    String? pinConfirmation,
  }) => _operation(() async {
    if (screen != VaultScreen.photoPassword) {
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    if (newPin != null) {
      _validatePinConfirmation(newPin, pinConfirmation ?? '');
    }
    final revision = _revision;
    // A prior interrupted password change may have committed a new generation.
    await _loadGate();
    _requireCurrent(revision);
    final pendingBytes = await _store.read(
      'repository-password-required',
      _installation!,
    );
    _requireCurrent(revision);
    final pending = pendingBytes == null
        ? null
        : SyncFormat.map(jsonDecode(utf8.decode(pendingBytes)));
    final session = await _gate!.authenticatePhotoPassword(
      password,
      repositoryRecovery: pending == null
          ? null
          : base64Decode(pending['recovery'] as String),
    );
    _requireCurrent(revision);
    if (pending != null) {
      final recoveredCatalog = LibraryCatalog.open(catalogFile, session);
      try {
        final key = 'sync:${pending['target']}';
        final prior = recoveredCatalog.record('preferences', key);
        if (prior == null)
          throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
        recoveredCatalog.putRecord('preferences', key, {
          ...prior,
          'acceptedRecoveryDigest': pending['digest'],
          'localGeneration': session.generation,
          'pendingPassword': null,
        });
      } finally {
        recoveredCatalog.close();
      }
    }
    if (newPin != null) {
      await _gate!.pinGate.configure(newPin);
    } else {
      await _gate!.pinGate.clearFailuresAfterPhotoAuthentication();
    }
    _requireCurrent(revision);
    await _gate!.recordPhotoAuthentication(session);
    _requireCurrent(revision);
    if (pending != null) {
      await _store.remove('repository-password-required');
      _requireCurrent(revision);
      repositoryPasswordRequired = false;
    }
    _gate!.lock();
    screen = VaultScreen.pin;
    message = '照片密码验证通过，请输入四位应用锁密码。';
  });

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
    required String confirmation,
  }) => _operation(() async {
    // Requires the previously verified PIN and a current, open catalog.
    catalog;
    final revision = _revision;
    final activeSync = sync;
    activeSync?.dispose();
    sync = null;
    await activeSync?.settled;
    _requireCurrent(revision);
    final crypto = await VaultCrypto.load();
    _requireCurrent(revision);
    final generation = _gate!.session.generation;
    // Reserve every previously initialized target before the credential service
    // replaces any wrapping. A failed local replacement is reconciled on restart.
    var after = '';
    var linked = false;
    while (true) {
      final page = catalog.recordPage(
        'preferences',
        'sync:github:',
        after: after,
      );
      if (page.isEmpty) break;
      after = page.last['recordId'] as String;
      catalog.transaction(() {
        for (final row in page) {
          final value = SyncFormat.map(row['body']);
          if (value['recoveryDigest'] == null) continue;
          if (value['pendingPassword'] != null) {
            throw const SecurityFailure(SecurityFailureCode.busy);
          }
          catalog.putRecord('preferences', row['recordId'] as String, {
            ...value,
            'pendingPassword': {
              'baselineDigest': value['recoveryDigest'],
              'oldGeneration': generation,
              'taskId': SyncFormat.newId(crypto),
            },
          });
          linked = true;
        }
      });
    }
    await _gate!.changePhotoPassword(
      oldPassword: oldPassword,
      newPassword: newPassword,
      confirmation: confirmation,
    );
    _requireCurrent(revision);
    _gate!.lock();
    screen = VaultScreen.pin;
    message = linked
        ? '本机照片密码已修改，仓库恢复材料待更新。解锁并恢复同步后会继续发布；尚未报告全端完成。'
        : '本机照片密码已修改，请输入应用锁密码。';
  });

  Future<RepositoryRecoveryPreview> inspectRepositoryRecovery() async {
    catalog;
    if (busy || github == null || github!.busy || sync?.busy == true) {
      throw const SecurityFailure(SecurityFailureCode.busy);
    }
    return github!.withRepository(RepositoryVaultRecovery.inspect);
  }

  Future<void> restoreRepository({
    required RepositoryRecoveryPreview expected,
    required String parent,
    required String password,
    required String pin,
    required String pinConfirmation,
  }) => _operation(() async {
    catalog;
    _validatePinConfirmation(pin, pinConfirmation);
    final destination = _locations.candidate(parent);
    if (VaultLocationStore.sameDirectory(destination, directory) ||
        await destination.exists())
      throw const SecurityFailure(SecurityFailureCode.alreadyExists);
    final revision = _revision;
    final active = sync;
    active?.dispose();
    sync = null;
    await active?.settled;
    _requireCurrent(revision);
    await github!.withRepository(
      (access) => RepositoryVaultRecovery.install(
        access: access,
        expected: expected,
        destination: destination,
        password: password,
        pin: pin,
        check: () {
          catalog;
          _requireCurrent(revision);
        },
      ),
    );
    _requireCurrent(revision);
    final handle = await File('${destination.path}/instance.lock')
        .open(mode: FileMode.append);
    var transferred = false;
    try {
      _platform.validatePrivatePath('${destination.path}/instance.lock');
      await handle.lock(FileLock.exclusive);
      _requireCurrent(revision);
      // The recovery form explicitly confirms switching to the new directory.
      // Publish the locator only after a fully authenticated, reopenable vault.
      await _locations.save(destination);
      _requireCurrent(revision);
      _gate!.lock();
      await _instanceLock?.close();
      _instanceLock = handle;
      transferred = true;
      _bindDirectory(destination);
      await _store.initialize();
      _installation = await _store.read(
        'installation',
        Uint8List.fromList(ascii.encode('EPA/installation/v1')),
      );
      _requireCurrent(revision);
      if (_installation?.length != 32)
        throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
      await _loadGate();
      _requireCurrent(revision);
      screen = VaultScreen.pin;
      message = '仓库清单已恢复到新数据目录。请输入新应用锁密码；原库保留。原始媒体按需下载，GitHub 需在新库重新授权。';
    } finally {
      if (!transferred) await handle.close();
    }
  });

  Future<void> _repositoryPasswordChanged(
    String target,
    Uint8List recovery,
    String digest,
  ) async {
    _workCatalog;
    final revision = _revision;
    final gate = _gate!;
    final wasBusy = _busy;
    _busy = true;
    gate.lock(); // Revoke media, keys and transfers before any awaited disk I/O.
    repositoryPasswordRequired = true;
    screen = VaultScreen.photoPassword;
    _notify();
    try {
      await _store.write(
        'repository-password-required',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'target': target,
              'recovery': base64Encode(recovery),
              'digest': digest,
            }),
          ),
        ),
        _installation!,
      );
      _requireCurrent(revision);
      message = '仓库照片密码已变化。请输入当前仓库照片密码，验证并采用后才能继续访问；并发改密未自动覆盖。';
    } catch (_) {
      if (!_closed) {
        screen = VaultScreen.failure;
        message = '无法保存仓库密码变更状态，访问已锁定。已有加密数据保留，请检查数据目录。';
      }
      rethrow;
    } finally {
      try {
        await gate.requirePhotoAuthentication();
      } finally {
        _busy = wasBusy;
        _notify();
      }
    }
  }

  void lock() {
    if (_closed) return;
    if (_backgroundCatalog == null || _gate!.requiresPhotoPassword) {
      suspend();
      return;
    }
    _revision++;
    _gate!.lockInterface();
    _hideInterface();
    github?.lockInterface();
    message = null;
    _notify();
  }

  /// System lock, suspend, shutdown and security failures revoke both scopes.
  void suspend() {
    if (_closed) return;
    _revision++;
    _gate?.lock();
    _credentials.revoke();
    _hideLibrary();
    if (_gate != null && _gate!.requiresPhotoPassword) {
      screen = VaultScreen.photoPassword;
    }
    message = null;
    _notify();
  }

  void _hideLibrary() {
    _hideInterface();
    sync?.dispose();
    sync = null;
    imports?.dispose();
    imports = null;
    github?.dispose();
    github = null;
    _backgroundCatalog?.close();
    _backgroundCatalog = null;
    _notify();
  }

  void _hideInterface() {
    organization?.dispose();
    organization = null;
    _catalog?.close();
    _catalog = null;
    accessEpoch++;
    if (screen == VaultScreen.library) screen = VaultScreen.pin;
    imports?.revokePreviews();
    sync?.revokeViewing();
  }

  Future<void> checkAccess() async {
    if (_checking || _busy || _closed || _gate == null) return;
    _checking = true;
    try {
      await _gate!.checkpoint();
    } catch (error) {
      _gate!.lock();
      screen = VaultScreen.photoPassword;
      message = describeFailure(error);
      _notify();
    } finally {
      _checking = false;
    }
  }

  Future<void> _operation(
    Future<void> Function() action, {
    bool preserveBackgroundOnPinFailure = false,
  }) async {
    if (_busy || _closed || _instanceLock == null) return;
    _busy = true;
    message = null;
    _notify();
    try {
      await action();
    } catch (error) {
      if (preserveBackgroundOnPinFailure &&
          _backgroundCatalog != null &&
          screen == VaultScreen.pin &&
          error is SecurityFailure &&
          ReverificationGate.isOrdinaryPinFailure(error) &&
          !_gate!.requiresPhotoPassword) {
        message = describeFailure(error);
        return;
      }
      _gate?.lock();
      _credentials.revoke();
      _hideLibrary();
      message = describeFailure(error);
      if (screen == VaultScreen.setup &&
          (_locationChanged || await _bootstrap.file.exists())) {
        screen = VaultScreen.failure;
        message = '初始化未完整完成，已有加密材料已保留。请勿删除或覆盖数据目录。';
      } else if (error is CatalogFailure) {
        screen = VaultScreen.failure;
      } else if (error is SecurityFailure &&
          error.code == SecurityFailureCode.pinSetupRequired) {
        screen = VaultScreen.photoPassword;
      } else if (_gate?.requiresPhotoPassword ?? false) {
        screen = VaultScreen.photoPassword;
      }
    } finally {
      _busy = false;
      _notify();
    }
  }

  static void _validatePinConfirmation(String pin, String confirmation) {
    PinGate.validate(pin);
    if (pin != confirmation) {
      throw const SecurityFailure(SecurityFailureCode.passwordMismatch);
    }
  }

  void _requireCurrent(int revision) {
    if (_closed || revision != _revision) {
      throw const SecurityFailure(SecurityFailureCode.cancelled);
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    final activeSync = sync;
    final activeImports = imports;
    suspend();
    _closed = true;
    _timer?.cancel();
    _gate?.onRevoke = null;
    await activeSync?.settled;
    await activeImports?.settled;
    final instanceLock = _instanceLock;
    _instanceLock = null;
    await instanceLock?.close();
    await _locations.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static String describeFailure(Object error) {
    if (error is SyncFailure) return WindowsSyncService.describe(error);
    if (error is CatalogFailure) {
      return switch (error.code) {
        CatalogFailureCode.unsupportedVersion => '照片库版本不受当前版本支持，已有数据已保留。',
        CatalogFailureCode.backendMismatch => '加密数据库组件校验失败，无法打开照片库。',
        _ => '无法安全读取或保存加密照片库，已有数据已保留。',
      };
    }
    if (error is SecurityFailure) {
      return switch (error.code) {
        SecurityFailureCode.invalidPassword =>
          '照片密码需为 12–128 个字符，不能全为空白或同一字符，也不能含控制字符。',
        SecurityFailureCode.passwordMismatch => '两次输入的密码不一致。',
        SecurityFailureCode.invalidPin => '应用锁密码必须为四位数字。',
        SecurityFailureCode.pinSetupRequired =>
          '应用锁材料缺失或损坏。请勾选“同时重新设置本机四位应用锁”，输入照片密码并设置新的四位密码。',
        SecurityFailureCode.authenticationFailed => '密码不正确，或受保护材料已损坏。',
        SecurityFailureCode.retryLater => '尝试次数过多，请稍后重试。等待时间在重启后仍然有效。',
        SecurityFailureCode.photoPasswordRequired =>
          '需要重新输入照片解密密码，验证通过前无法查看或同步。',
        SecurityFailureCode.busy => '照片库正在使用或处理请求，请关闭其他客户端后重试。',
        SecurityFailureCode.cancelled => '应用已锁定，本次操作已取消。',
        SecurityFailureCode.incompleteMaterial => '加密材料不完整，已有数据已保留，未创建空库覆盖。',
        SecurityFailureCode.alreadyExists => '保存位置中已有文件或文件夹，未覆盖。请选择其他位置。',
        _ => '安全存储或加密服务不可用，无法继续。已有数据已保留。',
      };
    }
    return '操作未完成，已有数据已保留。';
  }
}
