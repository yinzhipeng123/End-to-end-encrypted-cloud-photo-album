import 'package:flutter/material.dart';

void main() => runApp(const PhotoVaultIosApp());

/// Keeps the existing unavailable-platform state explicit during the split.
/// Sharing source code does not enable the pending iOS native backends.
class PhotoVaultIosApp extends StatelessWidget {
  const PhotoVaultIosApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '密屿',
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      appBar: AppBar(title: const Text('密屿')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '当前版本仅开放 Windows，iOS 功能尚未完成。',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}
