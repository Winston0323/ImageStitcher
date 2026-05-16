import 'dart:io';

class ImageItem {
  final File file;
  final String name;

  ImageItem({
    required this.file,
    required this.name,
  });
}

enum StitchMode {
  horizontal, // 按宽度对齐（水平拼接）
  vertical,   // 按长度对齐（垂直拼接）
}
