import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
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
  double _progress = 0.0;
  String? _resultPath;

  // 预览数据
  Uint8List? _previewBytes;
  int _lastProgressMs = 0;  // 节流：限制setState频率

  @override
  Widget build(BuildContext context) {
    // 处理中也保留预览（显示旧数据），避免UI塌陷
    final showPreview = _previewBytes != null;
    final hasImages = _selectedImages.isNotEmpty;

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
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: hasImages
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左侧面板
                      Expanded(
                        flex: showPreview ? 1 : 0,
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildModeSelector(),
                              const SizedBox(height: 12),
                              _buildAddButton(),
                              const SizedBox(height: 12),
                              _buildImageList(),
                              if (!showPreview || _selectedImages.length < 2) ...[
                                const SizedBox(height: 12),
                                _buildActionButtons(),
                              ],
                              const SizedBox(height: 16),
                              if (_resultPath != null) ...[
                                _buildResultSection(),
                                const SizedBox(height: 12),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // 分隔线
                      if (showPreview) ...[
                        const SizedBox(width: 12),
                        Container(width: 1, color: Colors.grey.shade300),
                        const SizedBox(width: 12),
                      ],

                      // 右侧预览区
                      if (showPreview)
                        Expanded(flex: 2, child: _buildPreviewPanel()),
                    ],
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildModeSelector(),
                        const SizedBox(height: 16),
                        _buildAddButton(),
                        const SizedBox(height: 16),
                        _buildImageList(),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
          ),

          if (_isProcessing) _buildProgressDialog(),
        ],
      ),
    );
  }

  // ========== 预览面板 ==========

  Widget _buildPreviewPanel() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.refresh, size: 20), tooltip: '刷新预览', onPressed: _selectedImages.length >= 2 ? _autoPreview : null),
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.save_alt, size: 20), tooltip: '保存图片', onPressed: _selectedImages.length >= 2 ? _saveFromPreview : null),
              ],
            ),
          ),
          Flexible(
            child: Container(color: Colors.grey[100], constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.65), child: InteractiveViewer(minScale: 0.15, maxScale: 8.0, boundaryMargin: const EdgeInsets.all(16), child: Center(child: Image.memory(_previewBytes!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 64, color: Colors.redAccent))))),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.grey.shade200))),
            child: FilledButton.icon(onPressed: _saveFromPreview, icon: const Icon(Icons.save, size: 18), label: const Text('保存此图片'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10))),
          ),
        ],
      ),
    );
  }

  // ========== 组件方法 ==========

  Widget _buildModeSelector() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.settings_suggest, size: 18, color: Colors.blue), SizedBox(width: 8), Text('拼接模式', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold))]),
        const SizedBox(height: 8),
        SegmentedButton<StitchMode>(segments: const [
          ButtonSegment(value: StitchMode.horizontal, label: Text('水平'), icon: Icon(Icons.view_column, size: 18)),
          ButtonSegment(value: StitchMode.vertical, label: Text('垂直'), icon: Icon(Icons.view_stream, size: 18)),
        ], selected: {_stitchMode}, onSelectionChanged: (selection) async { setState(() => _stitchMode = selection.first); await _autoPreview(); }),
        _modeHint(_stitchMode == StitchMode.horizontal ? '按宽度对齐，横向排列（统一高度）' : '按长度对齐，纵向排列（统一宽度）'),
      ])),
    );
  }

  Widget _modeHint(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)), child: Text(text, style: TextStyle(fontSize: 12, color: Colors.grey[700]))),
  );

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
      ConstrainedBox(constraints: BoxConstraints(maxHeight: 300), child: ListView.builder(shrinkWrap: true, itemCount: _selectedImages.length, itemBuilder: (context, index) {
        final item = _selectedImages[index];
        return Dismissible(key: ValueKey(item.file.path), direction: DismissDirection.endToStart, onDismissed: (_) { setState(() => _selectedImages.removeAt(index)); _autoPreview(); },
          background: Container(alignment: Alignment.centerRight, margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.only(right: 12), color: Colors.red, child: const Icon(Icons.delete, color: Colors.white)),
          child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 6), dense: true, leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.file(item.file, width: 44, height: 44, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholderIcon())),
            title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 13)), subtitle: Text('#${index + 1}', style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600)),
            trailing: IconButton(iconSize: 18, icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent), onPressed: () { setState(() => _selectedImages.removeAt(index)); _autoPreview(); }),
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

  Widget _buildActionButtons() => Card(
    child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      Expanded(child: FilledButton.icon(onPressed: (_selectedImages.length < 2 || _isProcessing) ? null : _autoPreview, icon: const Icon(Icons.preview, size: 18), label: Text(_isProcessing ? '处理中...' : '生成预览'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)))),
      const SizedBox(width: 10),
      Expanded(child: FilledButton.tonal(onPressed: (_selectedImages.length < 2 || _isProcessing) ? null : _saveStitched, style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)), child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.save_alt, size: 18), SizedBox(width: 6), Text('保存图片')]))),
    ])));

  Widget _buildProgressDialog() => Positioned(bottom: 0, left: 0, right: 0, child: Material(elevation: 8, color: Theme.of(context).colorScheme.surface, child: SafeArea(
    top: false, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue)),
        const SizedBox(width: 10),
        const Text('正在生成预览...', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
        const Spacer(), Text('${(_progress * 100).toInt()}%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFeatures: [FontFeature.tabularFigures()])),
      ]),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: _progress),
    ])))));

  Widget _placeholderIcon() => Container(width: 44, height: 44, color: Colors.grey[200], child: const Icon(Icons.image, color: Colors.grey, size: 22));

  // ========== 核心功能 ==========

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp', 'gif'], allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      for (var file in result.files) {
        if (file.path == null) continue;
        setState(() => _selectedImages.add(ImageItem(file: File(file.path!), name: file.name ?? '')));
      }
      if (_selectedImages.length >= 2) await _autoPreview();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加 ${result.files.length} 张图片'), duration: const Duration(seconds: 1)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择失败: $e')));
    }
  }

  Future<void> _autoPreview() async {
    if (_selectedImages.length < 2) { setState(() => _previewBytes = null); return; }
    // 保留旧预览显示，不清空！避免UI塌陷
    setState(() { _isProcessing = true; _progress = 0.0; });
    try {
      final imageBytes = await _getSelectedImageBytes();
      final stitchedBytes = await ImageStitcherService.stitchImages(imageBytes, mode: _stitchMode, onProgress: (p) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastProgressMs > 100 || p >= 1.0) {
          _lastProgressMs = now;
          // 关键：推到 microtask，避免在设备更新期间 setState 导致 mouse_tracker 崩溃
          Future.microtask(() { if (mounted) setState(() => _progress = p); });
        }
      });
      if (mounted) setState(() => _previewBytes = stitchedBytes);
    } catch (e) {
      // 失败也保留旧预览（如果有），不清空
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _saveFromPreview() async {
    if (_previewBytes == null) return;
    await _saveStitchedFromBytes(_previewBytes!);
  }

  Future<void> _saveStitched() async {
    setState(() { _isProcessing = true; _progress = 0.0; });
    try {
      final imageBytes = await _getSelectedImageBytes();
      final stitchedBytes = await ImageStitcherService.stitchImages(imageBytes, mode: _stitchMode, onProgress: (p) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastProgressMs > 100 || p >= 1.0) {
          _lastProgressMs = now;
          Future.microtask(() { if (mounted) setState(() => _progress = p); });
        }
      });
      await _saveStitchedFromBytes(stitchedBytes);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拼接失败: $e')));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _reorderImages() {
    final reordered = List<ImageItem>.from(_selectedImages);
    showDialog(context: context, builder: (ctx) => AlertDialog(title: const Row(children: [Icon(Icons.sort, size: 20), SizedBox(width: 8), Text('调整图片顺序')]), content: SizedBox(width: double.maxFinite, height: 320, child: ReorderableListView.builder(shrinkWrap: true, itemCount: reordered.length, onReorder: (oldIndex, newIndex) {
      setState(() { if (newIndex > oldIndex) newIndex--; final item = reordered.removeAt(oldIndex); reordered.insert(newIndex, item); _selectedImages.clear(); _selectedImages.addAll(reordered); });
      _autoPreview();
    }, itemBuilder: (ctx, index) {
      final item = reordered[index];
      return ListTile(key: ValueKey(item.file.path), dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), leading: CircleAvatar(radius: 14, backgroundColor: Theme.of(ctx).colorScheme.primary, foregroundColor: Colors.white, child: Text('${index + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))), title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 13)), trailing: const Icon(Icons.drag_handle, color: Colors.grey, size: 20));
    })), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('完成'))]));
  }

  Future<void> _saveStitchedFromBytes(Uint8List bytes) async {
    final savedPath = await FilePicker.platform.saveFile(dialogTitle: '保存拼接后的图片', fileName: 'stitched_${_stitchMode == StitchMode.horizontal ? "H" : "V"}_${DateTime.now().millisecondsSinceEpoch}.png', type: FileType.custom, allowedExtensions: ['png']);
    if (savedPath != null && savedPath.isNotEmpty) {
      await File(savedPath).writeAsBytes(bytes);
      setState(() => _resultPath = savedPath);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存至: $savedPath'), duration: const Duration(seconds: 3)));
    }
  }

  Future<List<Uint8List>> _getSelectedImageBytes() async => [for (var item in _selectedImages) await item.file.readAsBytes()];
}
