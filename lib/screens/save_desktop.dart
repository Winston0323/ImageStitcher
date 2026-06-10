/// 桌面端保存：写入本地文件
import 'dart:io';
import 'dart:typed_data';

Future<void> saveImage(Uint8List bytes, String path) async {
  await File(path).writeAsBytes(bytes);
}
