/// 图片保存 — 平台条件导出：
///   Web（dart.library.html）→ 浏览器下载
///   桌面端 → 本地文件写入
library save_image;

export 'save_desktop.dart'
    if (dart.library.html) 'save_web.dart';
