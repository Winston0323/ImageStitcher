import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:ffi_jpeg_encode/ffi_jpeg_encode.dart';

import '../models/image_item.dart';

/// 图片拼接服务 - GPU Canvas + 原生 PNG 编码
class ImageStitcherService {

  /// 拼接多张图片
  /// [maxPreviewDim] 预览时限制最大边长（如2048），保存时传0表示不缩放
  /// [jpegQuality] JPEG编码质量 (1-100)，默认95
  /// [outputLossless] 为 true 时使用 PNG 无损编码，否则 JPEG
  /// [addBorder] 是否给每张图片添加边框
  /// [borderColor] 边框颜色
  /// [borderPercent] 边框宽度占参考尺寸的百分比 (1.0-10.0)，水平模式参考高度，垂直模式参考宽度
  static Future<Uint8List> stitchImages(
    List<Uint8List> images, {
    required StitchMode mode,
    void Function(double progress)? onProgress,
    void Function(String message)? onLog,
    int maxPreviewDim = 0,  // 0=原始尺寸, >0=缩放到此最大边长
    int jpegQuality = 95,   // JPEG质量 1-100
    bool outputLossless = true,
    bool addBorder = false,
    ui.Color borderColor = const ui.Color(0xFF000000),
    double borderPercent = 3.0,
  }) async {
    if (images.isEmpty) throw Exception('没有可拼接的图片');
    if (images.length == 1) return images.first;

    final sw = Stopwatch()..start();
    void log(String msg) {
      final elapsed = sw.elapsedMilliseconds;
      final line = '[${elapsed.toString().padLeft(6)}ms] $msg';
      onLog?.call(line);
      debugPrint('[ImageStitcher] $line');
    }

    // ========== Step 1: 异步解码 ==========
    log('开始解码 ${images.length} 张图片...');
    onProgress?.call(0.01);
    final futures = images.map((bytes) => _decodeImageFromBytes(bytes)).toList();
    final results = await Future.wait(futures);
    final decodedImages = results.whereType<ui.Image>().toList();
    if (decodedImages.isEmpty) throw Exception('无法解码任何图片');
    log('✅ 解码完成 (${decodedImages.length}张), 尺寸: ${decodedImages.map((e) => "${e.width}×${e.height}").join(', ')}');
    onProgress?.call(0.18);

    // ========== Step 2: 计算画布尺寸 ==========
    log('计算画布尺寸...');
    int canvasWidth, canvasHeight;
    List<ui.Rect> dstRects;
    int bw = 0;

    if (mode == StitchMode.horizontal) {
      int maxHeight = decodedImages.map((e) => e.height).reduce((a, b) => a > b ? a : b);
      int totalWidth = 0;
      dstRects = [];
      if (addBorder) {
        bw = (maxHeight * borderPercent / 100).round().clamp(1, 9999);
        log('📐 边框宽度: $bw px (参考高度=${maxHeight}px, ${borderPercent}%)');
      }
      for (var src in decodedImages) {
        final w = (src.width * maxHeight / src.height).round();
        dstRects.add(ui.Rect.fromLTWH(totalWidth.toDouble(), 0, w.toDouble(), maxHeight.toDouble()));
        totalWidth += w;
      }
      canvasWidth = totalWidth + bw * (decodedImages.length + 1);
      canvasHeight = maxHeight + 2 * bw;
      if (addBorder) {
        double offsetX = bw.toDouble();
        for (int i = 0; i < dstRects.length; i++) {
          dstRects[i] = ui.Rect.fromLTWH(
            offsetX, bw.toDouble(),
            dstRects[i].width, dstRects[i].height,
          );
          offsetX += dstRects[i].width + bw;
        }
      }
    } else {
      int maxWidth = decodedImages.map((e) => e.width).reduce((a, b) => a > b ? a : b);
      int totalHeight = 0;
      dstRects = [];
      if (addBorder) {
        bw = (maxWidth * borderPercent / 100).round().clamp(1, 9999);
        log('📐 边框宽度: $bw px (参考宽度=${maxWidth}px, ${borderPercent}%)');
      }
      for (var src in decodedImages) {
        final h = (src.height * maxWidth / src.width).round();
        dstRects.add(ui.Rect.fromLTWH(0, totalHeight.toDouble(), maxWidth.toDouble(), h.toDouble()));
        totalHeight += h;
      }
      canvasWidth = maxWidth + 2 * bw;
      canvasHeight = totalHeight + bw * (decodedImages.length + 1);
      if (addBorder) {
        double offsetY = bw.toDouble();
        for (int i = 0; i < dstRects.length; i++) {
          dstRects[i] = ui.Rect.fromLTWH(
            bw.toDouble(), offsetY,
            dstRects[i].width, dstRects[i].height,
          );
          offsetY += dstRects[i].height + bw;
        }
      }
    }
    final pixelCount = (canvasWidth * canvasHeight / 1000000).toStringAsFixed(1);
    log('✅ 原始画布: ${canvasWidth}×${canvasHeight} ($pixelCount MP)');
    onProgress?.call(0.24);

    // 计算输出缩放比例（预览模式）
    double scale = 1.0;
    int outW = canvasWidth, outH = canvasHeight;
    if (maxPreviewDim > 0 && (canvasWidth > maxPreviewDim || canvasHeight > maxPreviewDim)) {
      scale = maxPreviewDim / (canvasWidth > canvasHeight ? canvasWidth : canvasHeight).toDouble();
      outW = (canvasWidth * scale).round();
      outH = (canvasHeight * scale).round();
      log('📐 缩放预览: ${(scale*100).toStringAsFixed(0)}% → ${outW}×${outH}');
    }

    // ========== Step 3: GPU Canvas 绘制 ==========
    log('GPU 绘制合成中...');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 白色背景
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasWidth.toDouble(), canvasHeight.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    for (int i = 0; i < decodedImages.length; i++) {
      final src = decodedImages[i];
      final dst = dstRects[i];

      if (addBorder) {
        // 在图片下方绘制边框（比图片略大一圈）
        canvas.drawRect(
          ui.Rect.fromLTWH(
            dst.left - bw, dst.top - bw,
            dst.width + 2 * bw, dst.height + 2 * bw,
          ),
          ui.Paint()..color = borderColor,
        );
      }

      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        dst,
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      onProgress?.call(0.24 + 0.48 * ((i + 1) / decodedImages.length));
      src.dispose();
    }

    log('Canvas 绘制完成，结束录制...');
    final picture = recorder.endRecording();

    // ========== Step 4: GPU 渲染为 Image ==========
    log('GPU 渲染 toImage 中 (${canvasWidth}×${canvasHeight})...');
    onProgress?.call(0.74);
    final resultImage = await picture.toImage(canvasWidth, canvasHeight);
    picture.dispose();
    log('✅ 渲染完成: ${resultImage.width}×${resultImage.height}');
    onProgress?.call(0.80);

    // ========== Step 5: 缩放（仅预览时） ==========
    ui.Image encodeImage = resultImage;

    if (scale < 1.0) {
      log('缩放中... ${canvasWidth}×${canvasHeight} → ${outW}×${outH}');
      onProgress?.call(0.82);
      final scaledRecorder = ui.PictureRecorder();
      final scaledCanvas = ui.Canvas(scaledRecorder);
      scaledCanvas.drawImageRect(
        resultImage,
        ui.Rect.fromLTWH(0, 0, canvasWidth.toDouble(), canvasHeight.toDouble()),
        ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      resultImage.dispose();
      final scaledPicture = scaledRecorder.endRecording();

      onProgress?.call(0.86);
      encodeImage = await scaledPicture.toImage(outW, outH);
      scaledPicture.dispose();
      log('✅ 缩放完成: ${encodeImage.width}×${encodeImage.height}, 像素数 ↓${((1-scale*scale).abs()*100).toStringAsFixed(0)}%');
      onProgress?.call(0.88);
    }

    // ========== Step 6: 编码导出 ==========
    final mp = (encodeImage.width * encodeImage.height / 1000000).toStringAsFixed(1);
    final isPreview = maxPreviewDim > 0;
    Uint8List outputBytes;

    if (isPreview || scale < 1.0) {
      // 预览模式 / 缩放过的小图 → 用 dart:ui 原生 PNG（稳定，无黑边风险）
      log('PNG 编码中 ($mp MP, 预览模式)...');
      onProgress?.call(0.90);
      final pngByteData = await encodeImage.toByteData(format: ui.ImageByteFormat.png);
      encodeImage.dispose();
      if (pngByteData == null) throw Exception('PNG编码失败');
      outputBytes = pngByteData.buffer.asUint8List(pngByteData.offsetInBytes, pngByteData.lengthInBytes);
      log('✅ PNG 导出完成! 文件大小: ${(outputBytes.length / 1024).toStringAsFixed(1)} KB');
    } else if (outputLossless) {
      // 全尺寸无损保存 → PNG
      log('PNG 无损编码中 ($mp MP)...');
      onProgress?.call(0.90);
      final pngByteData = await encodeImage.toByteData(format: ui.ImageByteFormat.png);
      encodeImage.dispose();
      if (pngByteData == null) throw Exception('PNG编码失败');
      outputBytes = pngByteData.buffer.asUint8List(pngByteData.offsetInBytes, pngByteData.lengthInBytes);
      log('✅ PNG 无损导出完成! 文件大小: ${(outputBytes.length / 1024).toStringAsFixed(1)} KB');
    } else {
      // 全尺寸保存模式 → 用 FFI+SIMD JPEG 加速（大图比PNG快5-20倍）
      log('JPEG 编码中 ($mp MP, quality=$jpegQuality)...');
      onProgress?.call(0.90);

      // 获取原始 RGBA 像素数据（rawRgba 有 GPU 行跨度填充，需去除）
      final byteData = await encodeImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      encodeImage.dispose();

      if (byteData == null) throw Exception('像素读取失败');

      final w = encodeImage.width;
      final h = encodeImage.height;
      final rowBytes = w * 4;
      final stride = byteData.lengthInBytes ~/ h;
      final tightPixels = Uint8List(w * h * 4);

      if (stride == rowBytes) {
        tightPixels.setAll(0, byteData.buffer.asUint8List(byteData.offsetInBytes, tightPixels.length));
      } else {
        final src = byteData.buffer.asUint8List(byteData.offsetInBytes);
        for (int y = 0; y < h; y++) {
          final srcOffset = y * stride;
          final dstOffset = y * rowBytes;
          tightPixels.setRange(dstOffset, dstOffset + rowBytes, src, srcOffset);
        }
        log('⚠️ 去除行跨度: stride=$stride rowBytes=$rowBytes');
      }

      outputBytes = encodeJpegToBytes(tightPixels, w, h, 4, quality: jpegQuality);
      log('✅ JPEG 导出完成! 文件大小: ${(outputBytes.length / 1024).toStringAsFixed(1)} KB');
    }

    onProgress?.call(1.0);
    log('═══ 全部完成，总耗时: ${sw.elapsedMilliseconds}ms ═══');
    return outputBytes;
  }

  /// 使用平台原生解码器异步解码图片
  static Future<ui.Image?> _decodeImageFromBytes(Uint8List bytes) async {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromList(bytes, (result) => completer.complete(result));
    return completer.future;
  }
}
