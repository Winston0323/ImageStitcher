/// 桌面端编码器 — rawRgba + jpeg_encode（纯 Dart，高性能）
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:jpeg_encode/jpeg_encode.dart';

class ImageEncoderImpl {
  static Future<Uint8List> encode(ui.Image image, {int quality = 95}) async {
    final w = image.width;
    final h = image.height;

    // 获取原始 RGBA 像素数据
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) throw Exception('像素读取失败');

    final rowBytes = w * 4;
    final stride = byteData.lengthInBytes ~/ h;
    final src = byteData.buffer.asUint8List(byteData.offsetInBytes);

    // 去除 GPU 行跨度填充 → 提取紧密排列的像素数据
    if (stride == rowBytes) {
      // 无填充：直接使用前 w*h*4 字节
      return JpegEncoder().compress(
        Uint8List.sublistView(src, 0, w * h * 4),
        w,
        h,
        quality,
      );
    } else {
      // 有行跨度填充：逐行复制
      final tightPixels = Uint8List(w * h * 4);
      for (int y = 0; y < h; y++) {
        final srcOffset = y * stride;
        final dstOffset = y * rowBytes;
        tightPixels.setRange(dstOffset, dstOffset + rowBytes, src, srcOffset);
      }
      return JpegEncoder().compress(tightPixels, w, h, quality);
    }
  }
}
