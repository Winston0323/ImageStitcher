import 'dart:io';
import 'dart:typed_data';

class ImageItem {
  final File file;
  final String name;
  Uint8List? thumbnailBytes;
  double? thumbWidth;
  double? thumbHeight;

  ImageItem({
    required this.file,
    required this.name,
    this.thumbnailBytes,
    this.thumbWidth,
    this.thumbHeight,
  });
}

enum StitchMode {
  horizontal, // 按宽度对齐（水平拼接）
  vertical,   // 按长度对齐（垂直拼接）
}
