library save_image;

/// Web 端保存：触发浏览器下载
import 'dart:typed_data';
import 'dart:html' as html;

Future<void> saveImage(Uint8List bytes, String fileName) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
}
