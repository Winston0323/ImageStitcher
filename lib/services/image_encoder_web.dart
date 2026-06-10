/// Web 端编码器 — 使用 png toByteData + Browser Canvas 转 JPEG
/// 解决 Web 端 rawRgba readPixels 为 null 的兼容性问题
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:html' as html;

class ImageEncoderImpl {
  /// Web 端编码：先转 PNG（浏览器原生稳定支持），再用 Canvas API 转 JPEG
  static Future<Uint8List> encode(ui.Image image, {int quality = 95}) async {
    // Web 端必须用 png 格式（rawRgba 底层调用 readPixels 会报错）
    final pngByteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (pngByteData == null) throw Exception('Web 像素读取失败');

    final pngBytes = pngByteData.buffer.asUint8List(pngByteData.offsetInBytes, pngByteData.lengthInBytes);

    // 将 PNG 数据转为 Blob URL，绘制到离屏 Canvas，再导出为 JPEG
    final blob = html.Blob([pngBytes], 'image/png');
    final url = html.Url.createObjectUrlFromBlob(blob);

    try {
      // 加载图片到 ImageElement
      final img = html.ImageElement();
      final completer = Completer<void>();
      img.onLoad.listen((_) => completer.complete());
      img.onError.listen((e) => completer.completeError(Exception('图片加载失败')));
      img.src = url;
      await completer.future;

      // 创建离屏 Canvas 并绘制
      final canvas = html.CanvasElement(width: image.width, height: image.height);
      final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;
      ctx.drawImage(img, 0, 0);

      // 导出为 JPEG（quality: 0.0~1.0）
      final jpegQuality = (quality / 100).clamp(0.01, 1.0);
      final dataUrl = canvas.toDataUrl('image/jpeg', jpegQuality);

      // 将 base64 DataURL 转回 Uint8List（浏览器原生 atob）
      final base64 = dataUrl.split(',').last;
      final binary = html.window.atob(base64);
      final bytes = Uint8List(binary.length);
      for (int i = 0; i < binary.length; i++) {
        bytes[i] = binary.codeUnitAt(i);
      }
      return bytes;
    } finally {
      html.Url.revokeObjectUrl(url);
    }
  }
}
