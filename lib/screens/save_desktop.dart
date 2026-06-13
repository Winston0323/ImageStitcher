/// 桌面端保存：写入本地文件
import 'dart:io';
import 'dart:typed_data';

Future<void> saveImage(Uint8List bytes, String path) async {
  await File(path).writeAsBytes(bytes);
}

/// 非 Web 平台无需此功能
Future<Uint8List> encodeRgbaToPng(int w, int h, Uint8List rgba) async {
  throw UnsupportedError('encodeRgbaToPng is only available on Web');
}
