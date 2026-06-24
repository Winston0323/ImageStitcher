/// 桌面端保存：写入本地文件 + RGBA→PNG 软编码
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

Future<void> saveImage(Uint8List bytes, String path) async {
  await File(path).writeAsBytes(bytes);
}

/// 纯 Dart PNG 编码（用 `image` 包，突破 GPU 纹理上限）
Future<Uint8List> encodeRgbaToPng(int w, int h, Uint8List rgba) async {
  final png = img.Image(width: w, height: h, numChannels: 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final off = (y * w + x) * 4;
      png.setPixelRgba(x, y, rgba[off], rgba[off + 1], rgba[off + 2], rgba[off + 3]);
    }
  }
  return Uint8List.fromList(img.encodePng(png));
}
