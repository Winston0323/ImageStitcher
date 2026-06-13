library save_image;

/// Web 端保存：触发浏览器下载
import 'dart:async';
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

/// Web 端利用浏览器原生 Canvas 将 RGBA 数据编码为 PNG（比纯 Dart 快 100 倍+）
Future<Uint8List> encodeRgbaToPng(int w, int h, Uint8List rgba) async {
  final canvas = html.CanvasElement(width: w, height: h);
  final ctx = canvas.context2D!;
  final imageData = ctx.createImageData(w, h);
  imageData.data.setAll(0, rgba);
  ctx.putImageData(imageData, 0, 0);
  final blob = await canvas.toBlob('image/png');
  final completer = Completer<Uint8List>();
  final reader = html.FileReader();
  reader.onLoadEnd.listen((_) {
    completer.complete(reader.result as Uint8List);
  });
  reader.readAsArrayBuffer(blob);
  return completer.future;
}
