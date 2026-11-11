import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/ui/production_screens.dart';
import 'package:encrypted_photo_app/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final item in {
      'SQLCipher Community 4.20.0': 'sqlcipher-LICENSE.md',
      'OpenSSL 4.1.0 (SQLCipher Windows)': 'openssl-LICENSE.txt',
      'sqlite3 Dart binding 3.9.1': 'sqlite3-LICENSE.txt',
      'libmpv full Windows build 2026-11-11': 'libmpv-full-GPL.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        item.key,
      ], await rootBundle.loadString('assets/licenses/${item.value}'));
    }
  });
  runApp(const PhotoVaultApp());
}

class PhotoVaultApp extends StatefulWidget {
  const PhotoVaultApp({super.key, this.controller});
  final VaultController? controller;
  @override
  State<PhotoVaultApp> createState() => _PhotoVaultAppState();
}

class _PhotoVaultAppState extends State<PhotoVaultApp>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('miyu/access');
  VaultController? _controller;
  String? _startupError;
  bool _shieldFramePending = false;
  int? _nativePrivacyEpoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.isWindows) {
      _startupError = '当前版本仅开放 Windows，iOS 功能尚未完成。';
      return;
    }
    try {
      _controller =
          widget.controller ??
          VaultController(VaultController.defaultDirectory());
      _controller!.addListener(_clearRevokedImages);
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'lock') {
          final arguments = call.arguments;
          final reason = arguments is Map ? arguments['reason'] : arguments;
          if (arguments is Map && arguments['epoch'] is int) {
            _nativePrivacyEpoch = arguments['epoch'] as int;
          }
          // Unknown/older native messages fail closed. Only an explicit
          // minimize event is allowed to keep the background session alive.
          _lock(background: reason == 'minimize');
        }
      });
      unawaited(_controller!.start());
    } catch (_) {
      _startupError = '无法初始化本机安全服务，未打开照片库。';
    }
  }

  void _lock({bool background = true}) {
    if (background) {
      _controller?.lock();
    } else {
      _controller?.suspend();
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  void _clearRevokedImages() {
    if (_controller?.screen != VaultScreen.library) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      unawaited(_releaseNativeShield());
    }
  }

  Future<void> _releaseNativeShield() async {
    final epoch = _nativePrivacyEpoch;
    if (_shieldFramePending || !mounted || epoch == null) return;
    _shieldFramePending = true;
    try {
      // The native neutral cover remains over a restored window until a
      // password-page frame has actually replaced the old Flutter surface.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _controller?.screen == VaultScreen.library) return;
      await _channel.invokeMethod<void>('lockedFrameReady', epoch);
    } on PlatformException {
      // Native cover, if present, stays in place; never reveal a cached frame.
    } on MissingPluginException {
      // Older runners remain fail-closed for access; production ships together.
    } finally {
      _shieldFramePending = false;
      if (epoch != _nativePrivacyEpoch &&
          mounted &&
          _controller?.screen != VaultScreen.library) {
        unawaited(_releaseNativeShield());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _lock(background: false);
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _lock();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.checkAccess());
      if (_controller?.screen != VaultScreen.library) {
        unawaited(_releaseNativeShield());
      }
    }
    // Inactive on Windows includes ordinary focus loss, which is not a lock.
  }

  Future<bool> _platformAvailable() async {
    try {
      final available = await _channel.invokeMethod<bool>('available') == true;
      if (!available) {
        final backgroundAvailable =
            await _channel.invokeMethod<bool>('backgroundAvailable') == true;
        if (backgroundAvailable) {
          // Minimized during a pending PIN submission: reject the UI unlock,
          // but do not revoke the already authorized background session.
          _lock();
        } else {
          _lock(background: false);
          _controller?.reportPlatformUnavailable();
        }
      }
      return available;
    } catch (_) {
      _lock(background: false);
      _controller?.reportPlatformUnavailable();
      return false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    _controller?.removeListener(_clearRevokedImages);
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  Widget _app(Widget home, {Key? key}) => MaterialApp(
    key: key,
    title: '密屿 · 加密相册',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return _app(Scaffold(body: Center(child: Text(_startupError!))));
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _app(
        controller.screen == VaultScreen.library
            ? ProductionShell(controller: controller, lock: _lock)
            : VaultAccessScreen(
                controller: controller,
                platformAvailable: _platformAvailable,
              ),
        // Every revocation destroys the Navigator, including open dialogs.
        key: ValueKey('${controller.screen}/${controller.accessEpoch}'),
      ),
    );
  }
}
