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

enum _ActiveTool { mode, border, image }

class _HomeScreenState extends State<HomeScreen> {
  final List<ImageItem> _selectedImages = [];
  StitchMode _stitchMode = StitchMode.horizontal;
  bool _isProcessing = false;
  _ActiveTool? _activeTool;

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
    final isWide = MediaQuery.of(context).size.width >= 600;

    final panel = <Widget>[
      const SizedBox(height: 12),
    ];

    Widget body;
    if (isWide) {
      // 桌面/平板宽屏：左右分栏
      if (Platform.isAndroid) {
        // Android 平板宽屏：预览居中，无分割线，不可滚动
        body = Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Spacer(),
                  _buildSubToolbar(),
                  _buildBottomToolbar(),
                ]),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: Center(child: _buildPreviewPanel())),
            ],
          ),
        );
      } else {
        body = Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: panel),
                      ),
                    ),
                    _buildSubToolbar(),
                    _buildBottomToolbar(),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(width: 1, color: Colors.grey.shade300),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: _buildPreviewPanel()),
            ],
          ),
        );
      }
    } else {
      // 窄屏（手机）
      if (Platform.isAndroid) {
        body = _buildAndroidNarrowLayout();
      } else {
        body = Padding(
          padding: const EdgeInsets.all(8),
          child: _buildNarrowLayout(),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('图片拼接工具'),
        actions: [
          if (_previewBytes != null && !_isProcessing)
            IconButton(
              icon: const Icon(Icons.save_alt),
              tooltip: '保存图片',
              onPressed: _saveFromPreview,
            ),
          if (_selectedImages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空列表',
              onPressed: () => setState(() {
                _selectedImages.clear();
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
    if (Platform.isAndroid) return _buildAndroidPreview();
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
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.refresh, size: 20), tooltip: '刷新预览', onPressed: (_selectedImages.isNotEmpty && !_isProcessing) ? _autoPreview : null),
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
                              Text('选择图片后\n将在此显示预览',
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
        ],
      ),
    );
  }

  /// Android 平台：无卡片边框，预览居中全屏显示
  Widget _buildAndroidPreview() {
    return Stack(
      alignment: Alignment.center,
      children: [
        _previewBytes != null
            ? InteractiveViewer(
                minScale: 0.15,
                maxScale: 8.0,
                boundaryMargin: const EdgeInsets.all(16),
                child: Center(
                  child: Image.memory(_previewBytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image, size: 64, color: Colors.redAccent)),
                ),
              )
            : Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.image_outlined, size: 64, color: Colors.grey[350]),
                  const SizedBox(height: 12),
                  Text('选择图片后\n将在此显示预览',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey[500], height: 1.5)),
                ]),
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
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(strokeWidth: 3, value: _saveProgress)),
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
    );
  }

  // ========== 组件方法 ==========

  Widget _buildNarrowLayout() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5,
                  ),
                  child: _buildPreviewPanel(),
                ),
              ],
            ),
          ),
        ),
        _buildSubToolbar(),
        _buildBottomToolbar(),
      ],
    );
  }

  /// Android 窄屏布局：固定布局不可滚动，预览居中占主要空间，控制区在底部
  Widget _buildAndroidNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 预览居中，填充主要空间
        Expanded(
          child: Center(child: _buildAndroidPreview()),
        ),
        const Divider(height: 1),
        // 底部紧凑控制区
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSubToolbar(),
            _buildBottomToolbar(),
          ],
        ),
      ],
    );
  }

  // ========== 底部工具栏 ==========

  /// 一排按钮，可横向滑动，固定在底部
  Widget _buildBottomToolbar() {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSafe + 8, left: 12, right: 12, top: 8),
      child: SizedBox(
        height: 64,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: _toolbarButton(
                  icon: Icons.add_photo_alternate_outlined,
                  label: '选择图片',
                  subtitle: _selectedImages.isEmpty ? '添加' : '${_selectedImages.length}张',
                  isActive: _activeTool == _ActiveTool.image,
                  onTap: () => _toggleTool(_ActiveTool.image),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: _toolbarButton(
                  icon: Icons.settings_suggest,
                  label: '拼接模式',
                  subtitle: _stitchMode == StitchMode.horizontal ? '水平' : '垂直',
                  isActive: _activeTool == _ActiveTool.mode,
                  enabled: _selectedImages.length > 1,
                  onTap: () => _toggleTool(_ActiveTool.mode),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 130,
                child: _toolbarButton(
                  icon: Icons.border_style,
                  label: '边框',
                  subtitle: _borderPercent > 0
                      ? '${_borderColorIndex == 0 ? "白色" : _borderColorIndex == 1 ? "黑色" : "彩虹"} ${_borderPercent.toInt()}%'
                      : '无',
                  isActive: _activeTool == _ActiveTool.border,
                  onTap: () => _toggleTool(_ActiveTool.border),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleTool(_ActiveTool tool) {
    // 只有一张图时不允许切换拼接模式
    if (tool == _ActiveTool.mode && _selectedImages.length <= 1) return;
    setState(() {
      _activeTool = _activeTool == tool ? null : tool;
    });
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool isActive,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = scheme.primary.withValues(alpha: 0.2);
    final defaultColor = scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final disabledColor = scheme.surfaceContainerHighest.withValues(alpha: 0.25);
    final isDisabled = !enabled;
    return Material(
      color: isDisabled ? disabledColor : (isActive ? activeColor : defaultColor),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isDisabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 20, color: isDisabled ? Colors.grey[400] : (isActive ? scheme.primary : scheme.primary.withValues(alpha: 0.7))),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDisabled ? Colors.grey[400] : (isActive ? scheme.primary : null))),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 10, color: isDisabled ? Colors.grey[400] : Colors.grey[600])),
                  ],
                ),
              ),
              Icon(
                isActive ? Icons.expand_more : Icons.expand_less,
                size: 18,
                color: isDisabled ? Colors.grey[400] : (isActive ? scheme.primary : Colors.grey[500]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 子工具栏（显示在主工具栏上方）==========

  /// 子工具栏容器
  Widget _buildSubToolbar() {
    if (_activeTool == null) return const SizedBox.shrink();

    Widget content;
    switch (_activeTool!) {
      case _ActiveTool.mode:
        content = _buildModeSubToolbar();
        break;
      case _ActiveTool.border:
        content = _buildBorderSubToolbar();
        break;
      case _ActiveTool.image:
        content = _buildImageSubToolbar();
        break;
    }

    final needsScroll = _activeTool == _ActiveTool.mode;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: needsScroll
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: content,
            )
          : content,
    );
  }

  // --- 拼接模式子工具栏 ---
  Widget _buildModeSubToolbar() {
    return Row(
      children: [
        _subChip(
          icon: Icons.view_column,
          label: '水平',
          hint: '横向排列',
          selected: _stitchMode == StitchMode.horizontal,
          onTap: () {
            setState(() => _stitchMode = StitchMode.horizontal);
            _autoPreview();
          },
        ),
        const SizedBox(width: 8),
        _subChip(
          icon: Icons.view_stream,
          label: '垂直',
          hint: '纵向排列',
          selected: _stitchMode == StitchMode.vertical,
          onTap: () {
            setState(() => _stitchMode = StitchMode.vertical);
            _autoPreview();
          },
        ),
      ],
    );
  }

  // --- 边框子工具栏 ---
  Widget _buildBorderSubToolbar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第一栏：颜色选择
        Row(
          children: [
            _subChip(
              color: Colors.white,
              label: '白色',
              selected: _borderColorIndex == 0,
              onTap: () {
                setState(() => _borderColorIndex = 0);
                _autoPreview();
              },
            ),
            const SizedBox(width: 8),
            _subChip(
              color: Colors.black,
              label: '黑色',
              selected: _borderColorIndex == 1,
              onTap: () {
                setState(() => _borderColorIndex = 1);
                _autoPreview();
              },
            ),
            const SizedBox(width: 8),
            _subChip(
              icon: Icons.gradient,
              label: '彩虹',
              selected: _borderColorIndex == 2,
              onTap: () {
                setState(() => _borderColorIndex = 2);
                _autoPreview();
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 第二栏：粗细调节
        Row(
          children: [
            Text('粗细', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            Expanded(
              child: Slider(
                value: _borderPercent,
                min: 0, max: 10, divisions: 10,
                label: '${_borderPercent.toInt()}%',
                onChanged: (v) => setState(() => _borderPercent = v),
                onChangeEnd: (_) => _autoPreview(),
              ),
            ),
            SizedBox(width: 30, child: Text('${_borderPercent.toInt()}%', style: const TextStyle(fontSize: 11))),
          ],
        ),
      ],
    );
  }

  // --- 选择图片子工具栏 ---
  Widget _buildImageSubToolbar() {
    final thumbHeight = 64.0;
    final thumbnailCount = _selectedImages.length;

    // empty state
    if (thumbnailCount == 0) {
      return Row(
        children: [
          _addImageBox(thumbHeight),
          const SizedBox(width: 16),
          _trashIcon(thumbHeight),
          const SizedBox(width: 12),
          Expanded(
            child: Text('点击 + 号添加图片',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ),
        ],
      );
    }

    // 计算所有缩略图总宽度
    double totalThumbWidth = 0;
    for (var item in _selectedImages) {
      double w = thumbHeight;
      if (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0) {
        w = thumbHeight * item.thumbWidth! / item.thumbHeight!;
      }
      totalThumbWidth += w + 8; // 8 = right padding
    }

    // 整体可左右滚动，加号在左、垃圾桶在右、缩略图在中间可长按拖拽
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _addImageBox(thumbHeight),
          const SizedBox(width: 8),
          SizedBox(
            width: totalThumbWidth,
            height: thumbHeight,
            child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: thumbnailCount,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _selectedImages.removeAt(oldIndex);
                    _selectedImages.insert(newIndex, item);
                  });
                  _autoPreview();
                },
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final scale = 1.0 + animation.value * 0.1;
                    return Transform.scale(
                      scale: scale,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        child: child,
                      ),
                    );
                  },
                  child: child,
                );
              },
              buildDefaultDragHandles: false,
              itemBuilder: (_, index) {
                final item = _selectedImages[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(item.file.path),
                  index: index,
                  child: _imageThumbItem(index, thumbHeight),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          _trashIcon(thumbHeight),
        ],
      ),
    );
  }

  Widget _imageThumbItem(int index, double thumbHeight) {
    final item = _selectedImages[index];
    double thumbWidth = thumbHeight;
    if (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0) {
      thumbWidth = thumbHeight * item.thumbWidth! / item.thumbHeight!;
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() {
            _selectedImages.removeAt(index);
            _autoPreview();
          }),
          child: Stack(
            children: [
              Container(
                width: thumbWidth,
                height: thumbHeight,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: item.thumbnailBytes != null
                      ? Image.memory(item.thumbnailBytes!, fit: BoxFit.cover)
                      : Image.file(item.file, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholderIcon()),
                ),
              ),
              // 序号角标
              Positioned(
                top: 2, left: 2,
                child: Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text('${index + 1}',
                      style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
              // 删除遮罩
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() {
                      _selectedImages.removeAt(index);
                      _autoPreview();
                    }),
                    child: const Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.cancel, size: 16, color: Colors.white, shadows: [Shadow(blurRadius: 3, color: Colors.black45)]),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addImageBox(double size) {
    return GestureDetector(
      onTap: _pickImages,
      child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey[400]!, width: 1.5, strokeAlign: BorderSide.strokeAlignInside),
            borderRadius: BorderRadius.circular(8),
            color: Colors.grey[100]?.withValues(alpha: 0.4),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.add, size: 28, color: Colors.grey[500]),
        ),
    );
  }

  Widget _trashIcon(double size) {
    final isEmpty = _selectedImages.isEmpty;
    final color = isEmpty ? Colors.grey[400]! : Colors.red[400]!;
    return GestureDetector(
      onTap: isEmpty ? null : () => setState(() {
        _selectedImages.clear();
        _previewBytes = null;
      }),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          border: Border.all(color: isEmpty ? Colors.grey[300]! : Colors.red[300]!, width: 1.5, strokeAlign: BorderSide.strokeAlignInside),
          borderRadius: BorderRadius.circular(8),
          color: (isEmpty ? Colors.grey : Colors.red).withValues(alpha: 0.06),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 20, color: color),
            const SizedBox(height: 2),
            Text('全部清空', style: TextStyle(fontSize: 9, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _subChip({
    IconData? icon,
    Color? color,
    required String label,
    String? hint,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.2) : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.7)),
                const SizedBox(width: 6),
              ] else if (color != null) ...[
                Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: color == Colors.white ? Border.all(color: Colors.grey[400]!) : null,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.8))),
              if (hint != null) ...[
                const SizedBox(width: 4),
                Text(hint, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ========== 已废弃的弹窗方法（保留以备后用）==========

  void _showModeSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              const Row(children: [
                Icon(Icons.settings_suggest, size: 20, color: Colors.blue),
                SizedBox(width: 8),
                Text('拼接模式', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 16),
              SegmentedButton<StitchMode>(
                segments: const [
                  ButtonSegment(value: StitchMode.horizontal, label: Text('水平'), icon: Icon(Icons.view_column, size: 18)),
                  ButtonSegment(value: StitchMode.vertical, label: Text('垂直'), icon: Icon(Icons.view_stream, size: 18)),
                ],
                selected: {_stitchMode},
                onSelectionChanged: (selection) {
                  setState(() => _stitchMode = selection.first);
                  setSheetState(() {});
                  _autoPreview();
                },
              ),
              const SizedBox(height: 8),
              _modeHint(_stitchMode == StitchMode.horizontal
                  ? '按宽度对齐，横向排列（统一高度）'
                  : '按长度对齐，纵向排列（统一宽度）'),
            ],
          ),
        ),
      ),
    );
  }

  void _showBorderSheet() {
    final colors = [Colors.white, Colors.black, null];
    final colorLabels = ['白色', '黑色', '彩虹'];
    final colorIcons = [null, null, Icons.gradient];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              const Row(children: [
                Icon(Icons.border_style, size: 20, color: Colors.blue),
                SizedBox(width: 8),
                Text('图片边框', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 16),
              Text('颜色：', style: TextStyle(fontSize: 13, color: Colors.grey[700])),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: List.generate(3, (i) => ChoiceChip(
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (colorIcons[i] != null) Icon(colorIcons[i], size: 14),
                    if (colors[i] != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: CircleAvatar(radius: 6, backgroundColor: colors[i]),
                      ),
                    Text(colorLabels[i], style: const TextStyle(fontSize: 12)),
                  ]),
                  selected: _borderColorIndex == i,
                  onSelected: (_) {
                    setState(() => _borderColorIndex = i);
                    setSheetState(() {});
                    _autoPreview();
                  },
                )),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Text('粗细：', style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                Expanded(child: Slider(
                  value: _borderPercent,
                  min: 0, max: 10, divisions: 10,
                  label: '${_borderPercent.toInt()}%',
                  onChanged: (v) {
                    setState(() => _borderPercent = v);
                    setSheetState(() {});
                  },
                  onChangeEnd: (_) => _autoPreview(),
                )),
                SizedBox(width: 32, child: Text('${_borderPercent.toInt()}%', style: const TextStyle(fontSize: 12))),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  void _showImageSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: _selectedImages.isEmpty ? 0.3 : 0.5,
          minChildSize: 0.25,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),
                const Row(children: [
                  Icon(Icons.add_photo_alternate_outlined, size: 20, color: Colors.blue),
                  SizedBox(width: 8),
                  Text('选择图片', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 16),
                // 添加按钮
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _pickImages();
                    },
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('从相册选择图片'),
                  ),
                ),
                if (_selectedImages.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('已选 ${_selectedImages.length} 张',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _reorderImages();
                        },
                        icon: const Icon(Icons.swap_vert, size: 16),
                        label: const Text('排序', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _selectedImages.length,
                      itemBuilder: (_, index) {
                        final item = _selectedImages[index];
                        return Dismissible(
                          key: ValueKey('sheet_${item.file.path}'),
                          direction: DismissDirection.endToStart,
                          onDismissed: (_) {
                            setState(() => _selectedImages.removeAt(index));
                            setSheetState(() {});
                            _autoPreview();
                          },
                          background: Container(
                            alignment: Alignment.centerRight,
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            padding: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                            dense: true,
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.file(item.file, width: 44, height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _placeholderIcon()),
                            ),
                            title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1,
                                style: const TextStyle(fontSize: 13)),
                            subtitle: Text('#${index + 1}',
                                style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600)),
                            trailing: IconButton(
                              iconSize: 18,
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                              onPressed: () {
                                setState(() => _selectedImages.removeAt(index));
                                setSheetState(() {});
                                _autoPreview();
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 24),
                  Center(
                    child: Column(children: [
                      Icon(Icons.image_not_supported_outlined, size: 48, color: Colors.grey[350]),
                      const SizedBox(height: 12),
                      Text('还没有选择任何图片', style: TextStyle(fontSize: 14, color: Colors.grey[500])),
                    ]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeHint(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)), child: Text(text, style: TextStyle(fontSize: 12, color: Colors.grey[700]))),
  );

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
        if (_selectedImages.isNotEmpty) _autoPreview();
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
        if (_selectedImages.isNotEmpty) _autoPreview();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择失败: $e')));
    }
  }

  Future<void> _generateThumbnail(ImageItem item) async {
    try {
      final bytes = await item.file.readAsBytes();
      final thumb = await ImageStitcherService.createThumbnail(bytes, percent: 10);
      // 解码缩略图获取尺寸
      final dims = await ImageStitcherService.getImageDimensions(thumb);
      if (mounted) {
        setState(() {
          item.thumbnailBytes = thumb;
          if (dims != null) {
            item.thumbWidth = dims.width.toDouble();
            item.thumbHeight = dims.height.toDouble();
          }
        });
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
    if (_selectedImages.isEmpty) {
      setState(() => _previewBytes = null);
      return;
    }
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
    if (_selectedImages.isEmpty) return;
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
        if (mounted) _showSaveSuccessDialog('已保存');
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
    if (mounted) _showSaveSuccessDialog('已保存到 Stitcher 相册');
  }

  void _showSaveSuccessDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 48),
            const SizedBox(height: 16),
            Text(message, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('保存成功', style: TextStyle(fontSize: 14, color: Colors.grey)),
          ],
        ),
      ),
    );
    // 1.5 秒后自动关闭
    Future.delayed(const Duration(milliseconds: 500), () {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
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
