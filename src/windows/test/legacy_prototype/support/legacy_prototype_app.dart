import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'model/demo_store.dart';
import 'ui/access_screen.dart';
import 'ui/home_shell.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const LegacyPrototypeApp());
}

class LegacyPrototypeApp extends StatefulWidget {
  const LegacyPrototypeApp({super.key, this.store, this.autoTick = true});
  final DemoStore? store;
  final bool autoTick;
  @override
  State<LegacyPrototypeApp> createState() => _LegacyPrototypeAppState();
}

class _LegacyPrototypeAppState extends State<LegacyPrototypeApp> {
  late final DemoStore store = widget.store ?? DemoStore();
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    if (widget.autoTick)
      _timer = Timer.periodic(
        const Duration(milliseconds: 1100),
        (_) => store.tick(),
      );
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.store == null) store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      // Replacing the entire Navigator disposes photo dialogs as well as the shell.
      // A dialog already on the stack must never remain above the password screen.
      final gateKey =
          '${store.configured}/${store.pinLocked}/${store.photoPasswordRequired}/${store.accessEpoch}';
      return MaterialApp(
        key: ValueKey(gateKey),
        title: '密屿 · 加密相册原型',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: !store.configured
            ? SetupScreen(store: store)
            : store.canView
            ? HomeShell(store: store)
            : AccessScreen(store: store),
      );
    },
  );
}
