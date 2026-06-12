import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 一张选中图片的信息
class PickedImage {
  final File file;
  final int width;
  final int height;

  PickedImage({required this.file, required this.width, required this.height});
}

/// 画廊选择器 —— 打开系统原生多图选择器（天然按原比例显示），选完直接返回
class GalleryPickerScreen {
  GalleryPickerScreen._();

  /// 返回选中的图片列表（含宽高）
  static Future<List<PickedImage>?> pick(BuildContext context) async {
    final xFiles = await ImagePicker().pickMultiImage(imageQuality: 100);
    if (xFiles.isEmpty) return null;

    // 显示加载中
    if (!context.mounted) return null;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final results = <PickedImage>[];
    for (final xf in xFiles) {
      try {
        final file = File(xf.path);
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        results.add(PickedImage(file: file, width: frame.image.width, height: frame.image.height));
        frame.image.dispose();
      } catch (_) {
        // 解码失败跳过
      }
    }

    if (context.mounted) Navigator.of(context).pop(); // 关闭 loading
    return results.isEmpty ? null : results;
  }
}
