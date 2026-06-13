import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';

import '../models/image_item.dart';

/// 图片拼接服务 - GPU Canvas + 原生 PNG 编码
class ImageStitcherService {

  /// 拼接多张图片
  /// [maxPreviewDim] 预览时限制最大边长（如2048），保存时传0表示不缩放
  /// [addBorder] 是否给每张图片添加边框
  /// [borderColor] 边框颜色（rainbowBorder=true 时无效）
  /// [borderPercent] 边框宽度占参考尺寸的百分比 (0-10)，水平模式参考高度，垂直模式参考宽度
  /// [rainbowBorder] 是否使用左上到右下的 hue 渐变彩虹边框
  static Future<Uint8List> stitchImages(
    List<Uint8List> images, {
    required StitchMode mode,
    void Function(double progress)? onProgress,
    void Function(String message)? onLog,
    int maxPreviewDim = 0,  // 0=原始尺寸, >0=缩放到此最大边长
    bool addBorder = false,
    ui.Color borderColor = const ui.Color(0xFF000000),
    double borderPercent = 3.0,
    bool rainbowBorder = false,
  }) async {
    if (images.isEmpty) throw Exception('没有可拼接的图片');
    if (images.length == 1 && !addBorder) return images.first;
    if (images.length == 1 && addBorder) {
      return await _addBorderToImage(images.first, borderPercent, borderColor, rainbowBorder, maxPreviewDim);
    }

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

    // 计算输出缩放比例
    // 预览：限制最大边长加速渲染；保存：不缩放，保留原图画质
    // Web 保存仅在超过 16383 时兜底（桌面 Chrome GPU 上限）
    double scale = 1.0;
    int outW = canvasWidth, outH = canvasHeight;
    if (maxPreviewDim > 0) {
      if (canvasWidth > maxPreviewDim || canvasHeight > maxPreviewDim) {
        scale = maxPreviewDim / (canvasWidth > canvasHeight ? canvasWidth : canvasHeight).toDouble();
        outW = (canvasWidth * scale).round();
        outH = (canvasHeight * scale).round();
        log('📐 预览缩放: ${(scale*100).toStringAsFixed(0)}% → ${outW}×${outH}');
      }
    } else if (kIsWeb) {
      const int webSaveMax = 16383;
      if (canvasWidth > webSaveMax || canvasHeight > webSaveMax) {
        scale = webSaveMax / (canvasWidth > canvasHeight ? canvasWidth : canvasHeight).toDouble();
        outW = (canvasWidth * scale).round();
        outH = (canvasHeight * scale).round();
        log('📐 Web保存缩放: ${(scale*100).toStringAsFixed(0)}% → ${outW}×${outH}');
      }
    }

    // ========== Step 3: GPU Canvas 绘制 ==========
    log('GPU 绘制合成中...');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 输出尺寸：缩放时用 outW×outH，否则原始尺寸
    final int drawW = scale < 1.0 ? outW : canvasWidth;
    final int drawH = scale < 1.0 ? outH : canvasHeight;
    final double s = scale < 1.0 ? scale : 1.0;

    ui.Rect scaledRect(double l, double t, double w, double h) =>
        ui.Rect.fromLTWH(l * s, t * s, w * s, h * s);

    // 白色背景（输出尺寸）
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, drawW.toDouble(), drawH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    for (int i = 0; i < decodedImages.length; i++) {
      final src = decodedImages[i];
      final dst = dstRects[i];

      if (addBorder) {
        final borderRect = scaledRect(
          dst.left - bw, dst.top - bw,
          dst.width + 2 * bw, dst.height + 2 * bw,
        );
        if (rainbowBorder) {
          final rainbowColors = [
            const ui.Color(0xFFFF0000),
            const ui.Color(0xFFFF7F00),
            const ui.Color(0xFFFFFF00),
            const ui.Color(0xFF00FF00),
            const ui.Color(0xFF0000FF),
            const ui.Color(0xFF4B0082),
            const ui.Color(0xFF8B00FF),
          ];
          final nColors = rainbowColors.length;
          final denom = (drawW + drawH).toDouble();
          final stepsX = math.max(1, math.min(256, borderRect.width.round()));
          final cellW = borderRect.width / stepsX;
          final stepsY = math.max(1, math.min(256, borderRect.height.round()));
          if (stepsY < 1) {
            final cx = borderRect.center.dx;
            final cy = borderRect.center.dy;
            final t = denom > 0 ? (cx + cy) / denom : 0.0;
            final pos = t * (nColors - 1);
            final ci = pos.floor().clamp(0, nColors - 2);
            final frac = pos - ci;
            final c0 = rainbowColors[ci];
            final c1 = rainbowColors[ci + 1];
            final r = c0.r * (1 - frac) + c1.r * frac;
            final g = c0.g * (1 - frac) + c1.g * frac;
            final b = c0.b * (1 - frac) + c1.b * frac;
            canvas.drawRect(borderRect, ui.Paint()..color = ui.Color.from(
              alpha: 1.0, red: r * 0.75 + 0.25, green: g * 0.75 + 0.25, blue: b * 0.75 + 0.25,
            ));
          } else {
            final cellH = borderRect.height / stepsY;
            for (int sx = 0; sx < stepsX; sx++) {
              for (int sy = 0; sy < stepsY; sy++) {
                final gx = borderRect.left + (sx + 0.5) * cellW;
                final gy = borderRect.top + (sy + 0.5) * cellH;
                final t = denom > 0 ? (gx + gy) / denom : 0.0;
                final pos = t * (nColors - 1);
                final ci = pos.floor().clamp(0, nColors - 2);
                final frac = pos - ci;
                final c0 = rainbowColors[ci];
                final c1 = rainbowColors[ci + 1];
                final r = c0.r * (1 - frac) + c1.r * frac;
                final g = c0.g * (1 - frac) + c1.g * frac;
                final b = c0.b * (1 - frac) + c1.b * frac;
                canvas.drawRect(
                  ui.Rect.fromLTWH(borderRect.left + sx * cellW, borderRect.top + sy * cellH,
                    cellW.ceilToDouble(), cellH.ceilToDouble()),
                  ui.Paint()..color = ui.Color.from(
                    alpha: 1.0, red: r * 0.75 + 0.25, green: g * 0.75 + 0.25, blue: b * 0.75 + 0.25,
                  ),
                );
              }
            }
          }
        } else {
          canvas.drawRect(borderRect, ui.Paint()..color = borderColor);
        }
      }

      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        scaledRect(dst.left, dst.top, dst.width, dst.height),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      onProgress?.call(0.24 + 0.48 * ((i + 1) / decodedImages.length));
      src.dispose();
    }

    log('Canvas 绘制完成，结束录制...');
    final picture = recorder.endRecording();

    // ========== Step 4: GPU 渲染为 Image ==========
    // 所有坐标已缩放到 drawW×drawH 内，直接渲染
    log('GPU 渲染 toImage 中 (${drawW}×${drawH})...');
    onProgress?.call(0.74);
    ui.Image encodeImage = await picture.toImage(drawW, drawH);
    picture.dispose();
    log('✅ 渲染完成: ${encodeImage.width}×${encodeImage.height}');
    onProgress?.call(0.88);

    // ========== Step 5: PNG 编码导出 ==========
    final mp = (encodeImage.width * encodeImage.height / 1000000).toStringAsFixed(1);
    log('PNG 编码中 ($mp MP)...');
    onProgress?.call(0.90);
    final pngByteData = await encodeImage.toByteData(format: ui.ImageByteFormat.png);
    encodeImage.dispose();
    if (pngByteData == null) throw Exception('PNG编码失败');
    final outputBytes = pngByteData.buffer.asUint8List(pngByteData.offsetInBytes, pngByteData.lengthInBytes);
    log('✅ PNG 导出完成! 文件大小: ${(outputBytes.length / 1024).toStringAsFixed(1)} KB');

    onProgress?.call(1.0);
    log('═══ 全部完成，总耗时: ${sw.elapsedMilliseconds}ms ═══');
    return outputBytes;
  }

  /// 为单张图片添加边框
  static Future<Uint8List> _addBorderToImage(
    Uint8List imageBytes,
    double borderPercent,
    ui.Color borderColor,
    bool rainbowBorder,
    int maxPreviewDim,
  ) async {
    final srcImage = await _decodeImageFromBytes(imageBytes);
    if (srcImage == null) throw Exception('无法解码图片');

    final bw = ((srcImage.width > srcImage.height ? srcImage.width : srcImage.height) * borderPercent / 100).round().clamp(1, 9999);
    final canvasW = srcImage.width + 2 * bw;
    final canvasH = srcImage.height + 2 * bw;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 白色背景
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 边框
    if (borderPercent > 0) {
      final borderRect = ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble());
      if (rainbowBorder) {
        final rainbowColors = [
          const ui.Color(0xFFFF0000), const ui.Color(0xFFFF7F00),
          const ui.Color(0xFFFFFF00), const ui.Color(0xFF00FF00),
          const ui.Color(0xFF0000FF), const ui.Color(0xFF4B0082),
          const ui.Color(0xFF8B00FF),
        ];
        final nColors = rainbowColors.length;
        final denom = (canvasW + canvasH).toDouble();
        final stepsX = math.max(1, math.min(256, borderRect.width.round()));
        final cellW = borderRect.width / stepsX;
        final stepsY = math.max(1, math.min(256, borderRect.height.round()));
        if (stepsY < 1) {
          final cx = borderRect.center.dx;
          final cy = borderRect.center.dy;
          final t = denom > 0 ? (cx + cy) / denom : 0.0;
          final pos = t * (nColors - 1);
          final ci = pos.floor().clamp(0, nColors - 2);
          final frac = pos - ci;
          final c0 = rainbowColors[ci];
          final c1 = rainbowColors[ci + 1];
          canvas.drawRect(borderRect, ui.Paint()..color = ui.Color.from(
            alpha: 1.0, red: c0.r * (1 - frac) + c1.r * frac,
            green: c0.g * (1 - frac) + c1.g * frac,
            blue: c0.b * (1 - frac) + c1.b * frac,
          ));
        } else {
          final cellH = borderRect.height / stepsY;
          for (int sx = 0; sx < stepsX; sx++) {
            for (int sy = 0; sy < stepsY; sy++) {
              final gx = borderRect.left + (sx + 0.5) * cellW;
              final gy = borderRect.top + (sy + 0.5) * cellH;
              final t = denom > 0 ? (gx + gy) / denom : 0.0;
              final pos = t * (nColors - 1);
              final ci = pos.floor().clamp(0, nColors - 2);
              final frac = pos - ci;
              final c0 = rainbowColors[ci];
              final c1 = rainbowColors[ci + 1];
              canvas.drawRect(
                ui.Rect.fromLTWH(borderRect.left + sx * cellW, borderRect.top + sy * cellH,
                  cellW.ceilToDouble(), cellH.ceilToDouble()),
                ui.Paint()..color = ui.Color.from(
                  alpha: 1.0, red: c0.r * (1 - frac) + c1.r * frac,
                  green: c0.g * (1 - frac) + c1.g * frac,
                  blue: c0.b * (1 - frac) + c1.b * frac,
                ),
              );
            }
          }
        }
      } else {
        canvas.drawRect(borderRect, ui.Paint()..color = borderColor);
      }
    }

    // 居中绘制图片
    canvas.drawImageRect(
      srcImage,
      ui.Rect.fromLTWH(0, 0, srcImage.width.toDouble(), srcImage.height.toDouble()),
      ui.Rect.fromLTWH(bw.toDouble(), bw.toDouble(), srcImage.width.toDouble(), srcImage.height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    srcImage.dispose();

    final picture = recorder.endRecording();
    ui.Image resultImage = await picture.toImage(canvasW, canvasH);
    picture.dispose();

    // 缩放预览
    if (maxPreviewDim > 0 && (canvasW > maxPreviewDim || canvasH > maxPreviewDim)) {
      final scale = maxPreviewDim / (canvasW > canvasH ? canvasW : canvasH).toDouble();
      final outW = (canvasW * scale).round();
      final outH = (canvasH * scale).round();
      final scaledRecorder = ui.PictureRecorder();
      final scaledCanvas = ui.Canvas(scaledRecorder);
      scaledCanvas.drawImageRect(
        resultImage,
        ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()),
        ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      resultImage.dispose();
      final scaledPicture = scaledRecorder.endRecording();
      resultImage = await scaledPicture.toImage(outW, outH);
      scaledPicture.dispose();
    }

    final pngData = await resultImage.toByteData(format: ui.ImageByteFormat.png);
    resultImage.dispose();
    if (pngData == null) throw Exception('PNG编码失败');
    return pngData.buffer.asUint8List(pngData.offsetInBytes, pngData.lengthInBytes);
  }

  /// 使用平台原生解码器异步解码图片
  static Future<ui.Image?> _decodeImageFromBytes(Uint8List bytes) async {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromList(bytes, (result) => completer.complete(result));
    return completer.future;
  }

  /// 生成缩略图，像素数量约为原图的 [percent]%
  /// [percent] 默认 10，表示 10% 像素（线性缩放约 31.6%）
  static Future<Uint8List> createThumbnail(Uint8List originalBytes, {double percent = 10}) async {
    final image = await _decodeImageFromBytes(originalBytes);
    if (image == null) throw Exception('缩略图解码失败');

    final srcW = image.width;
    final srcH = image.height;

    // 像素百分比 → 线性缩放比例
    final scale = math.sqrt(percent / 100).clamp(0.01, 1.0);
    int dstW = (srcW * scale).round();
    int dstH = (srcH * scale).round();

    // 保持比例的前提下限制最小/最大尺寸
    final minDim = dstW < dstH ? dstW : dstH;
    if (minDim < 64) {
      final adjust = 64.0 / minDim;
      dstW = (dstW * adjust).round();
      dstH = (dstH * adjust).round();
    }
    final maxDim = dstW > dstH ? dstW : dstH;
    if (maxDim > 4096) {
      final adjust = 4096.0 / maxDim;
      dstW = (dstW * adjust).round();
      dstH = (dstH * adjust).round();
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
      ui.Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    image.dispose();

    final picture = recorder.endRecording();
    final scaledImage = await picture.toImage(dstW, dstH);
    picture.dispose();

    final byteData = await scaledImage.toByteData(format: ui.ImageByteFormat.png);
    scaledImage.dispose();
    if (byteData == null) throw Exception('缩略图编码失败');

    return byteData.buffer.asUint8List();
  }

  /// 获取图片尺寸（不解码全图，只读取头部）
  static Future<({int width, int height})?> getImageDimensions(Uint8List bytes) async {
    final image = await _decodeImageFromBytes(bytes);
    if (image == null) return null;
    final w = image.width;
    final h = image.height;
    image.dispose();
    return (width: w, height: h);
  }
}
