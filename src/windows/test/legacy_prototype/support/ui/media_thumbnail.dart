import 'dart:io';

import 'package:flutter/material.dart';
import 'package:encrypted_photo_shared/model/media_item.dart';

class MediaThumbnail extends StatelessWidget {
  const MediaThumbnail({
    super.key,
    required this.item,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
  });
  final MediaItem item;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    Widget fallback([String? message]) => Container(
      width: width,
      height: height,
      color: const Color(0xFF233D33),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            item.kind == MediaKind.video
                ? Icons.videocam_outlined
                : Icons.image_not_supported_outlined,
            color: Colors.white70,
            size: 32,
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                message,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
        ],
      ),
    );
    if (item.asset.isEmpty) return fallback('封面暂不可用');
    if (item.isDemo) {
      return Image.asset(
        item.asset,
        fit: fit,
        width: width,
        height: height,
        cacheWidth: cacheWidth,
        errorBuilder: (_, error, stack) => fallback('封面读取失败'),
      );
    }
    return Image.file(
      File(item.asset),
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      errorBuilder: (_, error, stack) => fallback('封面读取失败'),
    );
  }
}
