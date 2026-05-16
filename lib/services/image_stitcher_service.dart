import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:image/image.dart' as image_lib;

import '../models/image_item.dart';

/// 图片拼接服务 - GPU Canvas + image 包 JPEG 编码
class ImageStitcherService {

  /// 拼接多张图片
  static Future<Uint8List> stitchImages(
    List<Uint8List> images, {
    required StitchMode mode,
    void Function(double progress)? onProgress,
  }) async {
    if (images.isEmpty) throw Exception('没有可拼接的图片');
    if (images.length == 1) return images.first;

    // ========== Step 1: 异步解码 (0% ~ 18%) ==========
    onProgress?.call(0.01);
    final futures = images.map((bytes) => _decodeImageFromBytes(bytes)).toList();
    final results = await Future.wait(futures);
    final decodedImages = results.whereType<ui.Image>().toList();
    if (decodedImages.isEmpty) throw Exception('无法解码任何图片');
    onProgress?.call(0.18);

    // ========== Step 2: 计算画布尺寸 (18% ~ 24%) ==========
    int canvasWidth, canvasHeight;
    List<ui.Rect> dstRects;

    if (mode == StitchMode.horizontal) {
      int maxHeight = decodedImages.map((e) => e.height).reduce((a, b) => a > b ? a : b);
      int totalWidth = 0;
      dstRects = [];
      for (var src in decodedImages) {
        final w = (src.width * maxHeight / src.height).round();
        dstRects.add(ui.Rect.fromLTWH(totalWidth.toDouble(), 0, w.toDouble(), maxHeight.toDouble()));
        totalWidth += w;
      }
      canvasWidth = totalWidth; canvasHeight = maxHeight;
    } else {
      int maxWidth = decodedImages.map((e) => e.width).reduce((a, b) => a > b ? a : b);
      int totalHeight = 0;
      dstRects = [];
      for (var src in decodedImages) {
        final h = (src.height * maxWidth / src.width).round();
        dstRects.add(ui.Rect.fromLTWH(0, totalHeight.toDouble(), maxWidth.toDouble(), h.toDouble()));
        totalHeight += h;
      }
      canvasWidth = maxWidth; canvasHeight = totalHeight;
    }
    onProgress?.call(0.24);

    // ========== Step 3: GPU Canvas 绘制合成 (24% ~ 72%) ==========
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 白色背景
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasWidth.toDouble(), canvasHeight.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 逐张绘制（GPU 双线性滤波缩放）
    for (int i = 0; i < decodedImages.length; i++) {
      final src = decodedImages[i];
      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        dstRects[i],
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      onProgress?.call(0.24 + 0.48 * ((i + 1) / decodedImages.length));
      src.dispose();
    }

    final picture = recorder.endRecording();

    // ========== Step 4: GPU 渲染为 Image (72% ~ 85%) ==========
    onProgress?.call(0.74);
    final resultImage = await picture.toImage(canvasWidth, canvasHeight);
    picture.dispose();

    // ========== Step 5: 导出 JPEG (85% ~ 100%) ==========
    onProgress?.call(0.85);

    // rawRgba 快速提取像素（几乎不耗时），再用 image 包编码为 JPEG
    final byteData = await resultImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    resultImage.dispose();

    if (byteData == null) throw Exception('图片导出失败');

    onProgress?.call(0.92);
    // image 包 JPEG 编码 — 比 dart:ui 原生 PNG 快 5-10 倍
    final img = image_lib.Image.fromBytes(
      width: canvasWidth,
      height: canvasHeight,
      bytes: byteData.buffer,
      numChannels: 4,
    );
    final jpegBytes = image_lib.JpegEncoder(quality: 92).encode(img);

    onProgress?.call(1.0);
    return jpegBytes;
  }

  /// 使用平台原生解码器异步解码图片
  static Future<ui.Image?> _decodeImageFromBytes(Uint8List bytes) async {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromList(bytes, (result) => completer.complete(result));
    return completer.future;
  }
}
