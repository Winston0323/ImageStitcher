import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 画廊选择器 —— 打开系统/浏览器图片选择器
class GalleryPickerScreen {
  GalleryPickerScreen._();

  /// 返回选中图片的 bytes + 宽高
  static Future<List<ImagePickResult>?> pick(BuildContext context) async {
    final xFiles = await ImagePicker().pickMultiImage(imageQuality: 100);
    if (xFiles.isEmpty) return null;

    if (!context.mounted) return null;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final results = <ImagePickResult>[];
    for (final xf in xFiles) {
      try {
        final bytes = await xf.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        // Web 上 xf.path 不可用，用 name 兜底
        String path;
        try {
          path = xf.path;
        } catch (_) {
          path = xf.name;
        }
        results.add(ImagePickResult(
          bytes: bytes,
          path: path,
          name: xf.name,
          width: frame.image.width,
          height: frame.image.height,
        ));
        frame.image.dispose();
      } catch (_) {}
    }

    if (context.mounted) Navigator.of(context).pop();
    return results.isEmpty ? null : results;
  }
}

/// 选择结果
class ImagePickResult {
  final Uint8List bytes;
  final String path;
  final String name;
  final int width;
  final int height;

  ImagePickResult({
    required this.bytes,
    required this.path,
    required this.name,
    required this.width,
    required this.height,
  });
}
