import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gal/gal.dart';
import '../models/image_item.dart';
import '../services/image_stitcher_service.dart';

/// 主界面 - 左右分栏布局
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<ImageItem> _selectedImages = [];
  StitchMode _stitchMode = StitchMode.horizontal;
  bool _isProcessing = false;
  String? _resultPath;

  // 保存进度
  double _saveProgress = 0.0;
  Timer? _saveTimer;

  // 边框设置
  int _borderColorIndex = 0; // 0=白色, 1=黑色
  double _borderPercent = 0.0;

  // 预览数据
  Uint8List? _previewBytes;

  @override
  Widget build(BuildContext context) {
    final hasImages = _selectedImages.isNotEmpty;
    final isWide = MediaQuery.of(context).size.width >= 600;

    final panel = <Widget>[
      _buildModeSelector(),
      const SizedBox(height: 12),
      _buildBorderSelector(),
      const SizedBox(height: 12),
      _buildAddButton(),
      const SizedBox(height: 12),
      _buildImageList(),
      const SizedBox(height: 16),
      if (_resultPath != null) ...[
        _buildResultSection(),
        const SizedBox(height: 12),
      ],
    ];

    Widget body;
    if (isWide) {
      body = Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 1, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: panel))),
            const SizedBox(width: 12),
            Container(width: 1, color: Colors.grey.shade300),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _buildPreviewPanel()),
          ],
        ),
      );
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: _buildNarrowLayout(),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('图片拼接工具'),
        actions: [
          if (_selectedImages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空列表',
              onPressed: () => setState(() {
                _selectedImages.clear();
                _resultPath = null;
                _previewBytes = null;
              }),
            ),
        ],
      ),
      body: body,
    );
  }

  // ========== 预览面板（常驻）==========

  Widget _buildPreviewPanel() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部工具栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
            child: Row(
              children: [
                const Icon(Icons.preview, size: 18, color: Colors.blue),
                const SizedBox(width: 8),
                Text('预览 (${_stitchMode == StitchMode.horizontal ? "水平" : "垂直"}拼接)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                if (_isProcessing)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                    ),
                  ),
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.refresh, size: 20), tooltip: '刷新预览', onPressed: (_selectedImages.length >= 2 && !_isProcessing) ? _autoPreview : null),
              ],
            ),
          ),
          // 内容区域
          Flexible(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 图片或占位
                _previewBytes != null
                    ? InteractiveViewer(
                        minScale: 0.15,
                        maxScale: 8.0,
                        boundaryMargin: const EdgeInsets.all(16),
                        child: Center(
                          child: Container(
                            color: Colors.grey[300],
                            child: Image.memory(_previewBytes!, fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 64, color: Colors.redAccent)),
                          ),
                        ),
                      )
                    : Center(
                        child: Container(
                          color: Colors.grey[300],
                          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.65),
                          child: Center(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.image_outlined, size: 64, color: Colors.grey[350]),
                              const SizedBox(height: 12),
                              Text('选择 2 张以上图片后\n将在此显示预览',
                                  textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey[500], height: 1.5)),
                            ]),
                          ),
                        ),
                      ),
                // 保存进度覆盖层
                if (_saveProgress > 0)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black45,
                      alignment: Alignment.center,
                      child: Card(
                        elevation: 6,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3, value: _saveProgress)),
                          const SizedBox(height: 16),
                          Text('正在保存... ${(_saveProgress * 100).toInt()}%',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          const SizedBox(height: 8),
                          SizedBox(width: 120, child: LinearProgressIndicator(value: _saveProgress)),
                        ])),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 保存按钮（仅预览可用时显示）
          if (_previewBytes != null && !_isProcessing)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: FilledButton.icon(onPressed: _saveFromPreview, icon: const Icon(Icons.save, size: 18), label: const Text('保存此图片'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10))),
            ),
        ],
      ),
    );
  }

  // ========== 组件方法 ==========

  Widget _buildNarrowLayout() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.5,
          ),
          child: _buildPreviewPanel(),
        ),
        const SizedBox(height: 8),
        _buildModeSelector(),
        const SizedBox(height: 8),
        _buildBorderSelector(),
        const SizedBox(height: 8),
        _buildAddButton(),
        const SizedBox(height: 8),
        if (_selectedImages.isNotEmpty) ...[
          _buildImageList(),
          const SizedBox(height: 8),
        ],
      if (_resultPath != null) ...[
        const SizedBox(height: 8),
        _buildResultSection(),
        const SizedBox(height: 8),
      ],
      ],
    );
  }

  Widget _buildModeSelector() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.settings_suggest, size: 18, color: Colors.blue), SizedBox(width: 8), Text('拼接模式', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold))]),
        const SizedBox(height: 8),
        SegmentedButton<StitchMode>(segments: const [
          ButtonSegment(value: StitchMode.horizontal, label: Text('水平'), icon: Icon(Icons.view_column, size: 18)),
          ButtonSegment(value: StitchMode.vertical, label: Text('垂直'), icon: Icon(Icons.view_stream, size: 18)),
        ], selected: {_stitchMode}, onSelectionChanged: (selection) { setState(() => _stitchMode = selection.first); _autoPreview(); }),
        _modeHint(_stitchMode == StitchMode.horizontal ? '按宽度对齐，横向排列（统一高度）' : '按长度对齐，纵向排列（统一宽度）'),
      ])),
    );
  }

  Widget _modeHint(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)), child: Text(text, style: TextStyle(fontSize: 12, color: Colors.grey[700]))),
  );

  Widget _buildBorderSelector() {
    final colors = [Colors.white, Colors.black, null];
    final colorLabels = ['白色', '黑色', '彩虹'];
    final colorIcons = [null, null, Icons.gradient];

    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.border_style, size: 18, color: Colors.blue), SizedBox(width: 8), Text('图片边框', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold))]),
        const SizedBox(height: 6),
        Row(children: [
          Text('颜色：', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          const SizedBox(width: 8),
          ...List.generate(3, (i) => Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                if (colorIcons[i] != null) Icon(colorIcons[i], size: 14),
                if (colors[i] != null) CircleAvatar(radius: 6, backgroundColor: colors[i]),
                const SizedBox(width: 4),
                Text(colorLabels[i], style: const TextStyle(fontSize: 12)),
              ]),
              selected: _borderColorIndex == i,
              onSelected: (_) => setState(() { _borderColorIndex = i; _autoPreview(); }),
            ),
          )),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Text('粗细：', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          Expanded(child: Slider(
            value: _borderPercent,
            min: 0, max: 10, divisions: 10,
            label: '${_borderPercent.toInt()}%',
            onChanged: (v) => setState(() => _borderPercent = v),
            onChangeEnd: (_) => _autoPreview(),
          )),
          SizedBox(width: 32, child: Text('${_borderPercent.toInt()}%', style: const TextStyle(fontSize: 12))),
        ]),
      ])),
    );
  }

  Widget _buildAddButton() => SizedBox(width: double.infinity, height: 80, child: Card(
    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.25),
    shape: RoundedRectangleBorder(side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4), width: 2), borderRadius: BorderRadius.circular(10)),
    child: InkWell(borderRadius: BorderRadius.circular(10), onTap: _pickImages, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.add_photo_alternate_outlined, size: 32, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 6),
      Text('点击添加图片', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w500)),
    ]))),
  ));

  Widget _buildImageList() {
    if (_selectedImages.isEmpty) {
      return Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        Icon(Icons.image_not_supported_outlined, size: 48, color: Colors.grey[400]),
        const SizedBox(height: 12),
        Text('还没有选择任何图片', style: TextStyle(fontSize: 15, color: Colors.grey[600])),
        const SizedBox(height: 6),
        Text('点击上方按钮开始选择', style: TextStyle(fontSize: 13, color: Colors.grey[500])),
      ])));
    }

    return Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [const Icon(Icons.photo_library, size: 18, color: Colors.blue), const SizedBox(width: 6), Text('已选 ${_selectedImages.length} 张', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))]),
        TextButton.icon(onPressed: _reorderImages, icon: const Icon(Icons.swap_vert, size: 16), label: const Text('排序', style: TextStyle(fontSize: 12))),
      ]),
      const Divider(height: 1),
      const SizedBox(height: 6),
      ConstrainedBox(constraints: BoxConstraints(maxHeight: 300), child: ListView.builder(shrinkWrap: true, primary: false, physics: const NeverScrollableScrollPhysics(), itemCount: _selectedImages.length, itemBuilder: (context, index) {
        final item = _selectedImages[index];
        return Dismissible(key: ValueKey(item.file.path), direction: DismissDirection.endToStart, onDismissed: (_) { setState(() => _selectedImages.removeAt(index)); _autoPreview(); },
          background: Container(alignment: Alignment.centerRight, margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.only(right: 12), color: Colors.red, child: const Icon(Icons.delete, color: Colors.white)),
          child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 6), dense: true, leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.file(item.file, width: 44, height: 44, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholderIcon())),
            title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 13)), subtitle: Text('#${index + 1}', style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600)),
            trailing: IconButton(iconSize: 18, icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent), onPressed: () => setState(() { _selectedImages.removeAt(index); _autoPreview(); })),
        ));
      })),
    ])));
  }

  Widget _buildResultSection() => Card(
    color: Colors.green.withValues(alpha: 0.06),
    shape: RoundedRectangleBorder(side: BorderSide(color: Colors.green.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(10)),
    child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.check_circle_outline, color: Colors.green, size: 20), SizedBox(width: 6), Text('保存成功!', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 14))]),
      const SizedBox(height: 4),
      SelectableText(_resultPath!, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
    ])));

  Widget _placeholderIcon() => Container(width: 44, height: 44, color: Colors.grey[200], child: const Icon(Icons.image, color: Colors.grey, size: 22));

  // ========== 核心功能 ==========

  Future<void> _pickImages() async {
    try {
      if (Platform.isAndroid) {
        // Android: 使用原生相册选取（多选）
        final images = await ImagePicker().pickMultiImage();
        if (images.isEmpty) return;
        final tasks = <Future<void>>[];
        for (var xFile in images) {
          final item = ImageItem(file: File(xFile.path), name: xFile.name);
          setState(() => _selectedImages.add(item));
          tasks.add(_generateThumbnail(item));
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加 ${images.length} 张图片'), duration: const Duration(seconds: 1)));
        // 等所有缩略图生成完再自动预览
        await Future.wait(tasks);
        if (_selectedImages.length >= 2) _autoPreview();
      } else {
        // 其他平台：使用 file_picker
        final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp', 'gif'], allowMultiple: true);
        if (result == null || result.files.isEmpty) return;
        final tasks = <Future<void>>[];
        for (var file in result.files) {
          if (file.path == null) continue;
          final item = ImageItem(file: File(file.path!), name: file.name ?? '');
          setState(() => _selectedImages.add(item));
          tasks.add(_generateThumbnail(item));
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加 ${result.files.length} 张图片'), duration: const Duration(seconds: 1)));
        // 等所有缩略图生成完再自动预览
        await Future.wait(tasks);
        if (_selectedImages.length >= 2) _autoPreview();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择失败: $e')));
    }
  }

  Future<void> _generateThumbnail(ImageItem item) async {
    try {
      final bytes = await item.file.readAsBytes();
      final thumb = await ImageStitcherService.createThumbnail(bytes, percent: 10);
      if (mounted) {
        setState(() => item.thumbnailBytes = thumb);
      }
    } catch (_) {
      // 缩略图生成失败不影响主流程
    }
  }

  Color get _borderUiColor {
    if (_borderColorIndex == 0) return Colors.white;
    if (_borderColorIndex == 1) return Colors.black;
    return Colors.black; // 彩虹模式下 borderColor 不会实际使用
  }
  bool get _isRainbowBorder => _borderColorIndex == 2;

  Future<void> _autoPreview() async {
    if (_selectedImages.length < 2) return; // 保留旧预览，不清空
    setState(() { _isProcessing = true; });
    try {
      final imageBytes = await _getThumbnailBytes();
      if (imageBytes == null) return; // 缩略图还没生成完，跳过
      final stitchedBytes = await ImageStitcherService.stitchImages(
        imageBytes,
        mode: _stitchMode,
        maxPreviewDim: 2048, // 预览缩放到最大边长2048，编码快10-50倍
        addBorder: _borderPercent > 0,
        borderColor: _borderUiColor,
        borderPercent: _borderPercent,
        rainbowBorder: _isRainbowBorder,
      );
      if (mounted) setState(() => _previewBytes = stitchedBytes);
    } catch (e) {
      // 失败也保留旧预览（如果有），不清空，但显示错误
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('预览生成失败: $e'), duration: const Duration(seconds: 5)));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _startSaveTimer() {
    _stopSaveTimer();
    _saveTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && (_saveProgress > 0 || _isProcessing)) {
        setState(() {});
      } else {
        _stopSaveTimer();
      }
    });
  }

  void _stopSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  @override
  void dispose() {
    _stopSaveTimer();
    super.dispose();
  }

  Future<void> _saveFromPreview() async {
    if (_selectedImages.length < 2) return;
    _startSaveTimer();
    setState(() { _isProcessing = true; _saveProgress = 0.0; });
    try {
      final imageBytes = await _getSelectedImageBytes();
      final fullResBytes = await ImageStitcherService.stitchImages(
        imageBytes,
        mode: _stitchMode,
        onProgress: (p) => _saveProgress = p,
        addBorder: _borderPercent > 0,
        borderColor: _borderUiColor,
        borderPercent: _borderPercent,
        rainbowBorder: _isRainbowBorder,
      );
      if (Platform.isAndroid || Platform.isIOS) {
        await _saveToDeviceAlbum(fullResBytes);
      } else {
        final savePath = await _pickSavePath(bytes: fullResBytes);
        if (savePath == null) return;
        await _writeBytesToPath(fullResBytes, savePath);
        setState(() => _resultPath = savePath);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存至: $savePath'), duration: const Duration(seconds: 3)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), duration: const Duration(seconds: 5)));
    } finally {
      _stopSaveTimer();
      if (mounted) setState(() { _isProcessing = false; _saveProgress = 0.0; });
    }
  }

  /// 保存图片到系统相册的 Stitcher 相簿中（Android/iOS）
  Future<void> _saveToDeviceAlbum(Uint8List bytes) async {
    await Gal.putImageBytes(bytes, album: 'Stitcher');
    setState(() => _resultPath = '相册 › Stitcher');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存到 Stitcher 相册'), duration: Duration(seconds: 2)),
      );
    }
  }

  void _reorderImages() {
    final reordered = List<ImageItem>.from(_selectedImages);
    showDialog(context: context, builder: (ctx) => AlertDialog(title: const Row(children: [Icon(Icons.sort, size: 20), SizedBox(width: 8), Text('调整图片顺序')]), content: SizedBox(width: double.maxFinite, height: 320,     child: ReorderableListView.builder(shrinkWrap: true, itemCount: reordered.length, onReorder: (oldIndex, newIndex) {
      setState(() { if (newIndex > oldIndex) newIndex--; final item = reordered.removeAt(oldIndex); reordered.insert(newIndex, item); _selectedImages.clear(); _selectedImages.addAll(reordered); }); _autoPreview();
    }, itemBuilder: (ctx, index) {
      final item = reordered[index];
      return ListTile(key: ValueKey(item.file.path), dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), leading: CircleAvatar(radius: 14, backgroundColor: Theme.of(ctx).colorScheme.primary, foregroundColor: Colors.white, child: Text('${index + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))), title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 13)), trailing: const Icon(Icons.drag_handle, color: Colors.grey, size: 20));
    })), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('完成'))]));
  }

  /// 让用户选择保存路径，固定 PNG 格式。Android/iOS 需传入 bytes 直接写入
  Future<String?> _pickSavePath({required Uint8List bytes}) async {
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: '保存拼接后的图片',
      fileName: 'stitched_${_stitchMode == StitchMode.horizontal ? "H" : "V"}_${DateTime.now().millisecondsSinceEpoch}.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
      bytes: bytes,
    );
    if (savedPath == null || savedPath.isEmpty) return null;
    return savedPath;
  }

  Future<void> _writeBytesToPath(Uint8List bytes, String savePath) async {
    // Android content:// URI 需要先写临时文件再复制
    if (savePath.startsWith('content://')) {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/stitch_temp.png');
      await tempFile.writeAsBytes(bytes);
      await tempFile.copy(savePath);
      await tempFile.delete();
    } else {
      await File(savePath).writeAsBytes(bytes);
    }
  }

  Future<List<Uint8List>> _getSelectedImageBytes() async => [for (var item in _selectedImages) await item.file.readAsBytes()];

  /// 获取所有图片的缩略图字节，如果任意缩略图尚未生成则返回 null
  Future<List<Uint8List>?> _getThumbnailBytes() async {
    final result = <Uint8List>[];
    for (var item in _selectedImages) {
      if (item.thumbnailBytes == null) return null; // 缩略图还没生成
      result.add(item.thumbnailBytes!);
    }
    return result;
  }
}
