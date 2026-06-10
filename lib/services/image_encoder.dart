/// 通用图片编码器 — 自动适配平台
/// - 桌面端：rawRgba + jpeg_encode（高性能）
/// - Web 端：png toByteData → Canvas → JPEG（兼容性优先）
library;

import 'dart:ui' as ui;
import 'dart:typed_data';

import 'image_encoder_web.dart' if (dart.library.io) 'image_encoder_desktop.dart';

/// 统一编码接口
abstract class ImageEncoder {
  static Future<Uint8List> encode(ui.Image image, {int quality = 95}) async {
    return ImageEncoderImpl.encode(image, quality: quality);
  }
}
