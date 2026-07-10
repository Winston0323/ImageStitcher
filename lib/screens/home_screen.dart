import 'dart:async';
import 'dart:io' show Platform, File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import '../models/image_item.dart';
import '../services/image_stitcher_service.dart';
import '../screens/save_image.dart';
import 'gallery_picker_screen.dart';

/// 主界面 - 左右分栏布局
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _ActiveTool { mode, border, image }

class _TileData {
  final int index;
  final double height;
  const _TileData({required this.index, required this.height});
}

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
  // （GPU 实时预览，不再需要 _previewBytes）
  // 真正的输出尺寸（根据原图尺寸+边框计算，非预览缩放后的尺寸）
  int? _outputWidth;
  int? _outputHeight;
  bool _showRuler = true;

  // 大预览图点选 + 角点拖拽缩放
  int? _selectedSubImageIndex;
  // 每张图的缩放因子 (1.0=100%, 3.0=300%)
  List<double> _imageScales = [];
  // 每张图的平移偏移（源像素，0,0=居中）
  List<Offset> _imageOffsets = [];
  // 图片拖拽平移：上一次指针位置
  Offset? _panLastPos;
  // 角点拖拽状态
  int _dragCornerIndex = 0;
  double _dragStartScale = 1.0;
  Offset _dragTotalDelta = Offset.zero;
  // 选中子图的源/显示像素比（用于拖拽转换）
  double _selectedSrcToDispRatio = 1.0;
  // 实时预览：缓存解码后的缩略图 ui.Image
  List<ui.Image?> _decodedThumbs = [];

  double _scaleOf(int index) =>
      index < _imageScales.length ? _imageScales[index] : 1.0;

  Offset _offsetOf(int index) =>
      index < _imageOffsets.length ? _imageOffsets[index] : Offset.zero;

  /// 所有缩略图都已解码，可以实时预览
  bool get _canLivePreview =>
      _selectedImages.isNotEmpty &&
      _decodedThumbs.length >= _selectedImages.length &&
      _decodedThumbs.every((e) => e != null);

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    Widget body;
    if (isWide) {
      body = _buildWideLayout();
    } else {
      // 窄屏（手机）
      if (!kIsWeb && Platform.isAndroid) {
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
          if (_selectedImages.isNotEmpty && !_isProcessing)
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
                _imageScales.clear();
                _decodedThumbs.clear();
                _imageOffsets.clear();
                _selectedSubImageIndex = null;
                _outputWidth = null;
                _outputHeight = null;
              }),
            ),
        ],
      ),
      body: body,
    );
  }

  // ========== 预览面板（常驻）==========

  Widget _buildPreviewPanel() {
    if (!kIsWeb && Platform.isAndroid) return _buildAndroidPreview();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部工具栏（去卡片化）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 0.5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.preview, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Text('${_stitchMode == StitchMode.horizontal ? "水平" : "垂直"}拼接',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              if (_outputWidth != null && _outputHeight != null) ...[
                const SizedBox(width: 8),
                Text('$_outputWidth × $_outputHeight px',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
              const Spacer(),
              if (_outputWidth != null)
                SizedBox(
                  width: 28, height: 28,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      _showRuler ? Icons.straighten : Icons.straighten_outlined,
                      size: 18,
                      color: _showRuler ? Colors.blue : Colors.grey,
                    ),
                    tooltip: _showRuler ? '关闭标尺' : '显示标尺',
                    onPressed: () => setState(() => _showRuler = !_showRuler),
                  ),
                ),
              if (_isProcessing)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                  ),
                ),
              SizedBox(
                width: 28, height: 28,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '刷新预览',
                  onPressed: (_selectedImages.isNotEmpty && !_isProcessing) ? _autoPreview : null,
                ),
              ),
            ],
          ),
        ),
        // 内容区域
        Expanded(
          child: _buildPreviewContent(),
        ),
      ],
    );
  }

  /// 预览内容区（图片 + 工程图标注 + 保存进度）
  Widget _buildPreviewContent() {
    // 标注线需要的额外空间
    const extPad = 32.0;
    return Stack(
      alignment: Alignment.center,
      children: [
        // 图片或占位
        if (_canLivePreview && _outputWidth != null && _outputHeight != null)
          InteractiveViewer(
            panEnabled: _selectedSubImageIndex == null,
            minScale: 0.15,
            maxScale: 8.0,
            boundaryMargin: const EdgeInsets.all(40),
            child: Center(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final containerW = constraints.maxWidth;
                  final containerH = constraints.maxHeight;
                  if (containerW <= 0 || containerH <= 0) return _buildEmptyPreview();
                  // 预留标注线空间
                  final availW = containerW - extPad;
                  final availH = containerH - extPad;
                  final imgAspect = _outputWidth! / _outputHeight!;
                  double dispW, dispH;
                  if (availW / availH > imgAspect) {
                    dispH = availH;
                    dispW = dispH * imgAspect;
                  } else {
                    dispW = availW;
                    dispH = dispW / imgAspect;
                  }
                  final left = (containerW - dispW) / 2;
                  final top = (containerH - dispH) / 2;
                  // 计算子图区域（用于点击检测和选中高亮）
                  final displayScaleX = dispW / _outputWidth!;
                  final displayScaleY = dispH / _outputHeight!;
                  final subRects = _buildSubRects(
                    left, top, displayScaleX, displayScaleY,
                  );
                  // 计算选中子图的源/显示像素比（供拖拽转换用）
                  if (_selectedSubImageIndex != null && _selectedSubImageIndex! < subRects.length) {
                    final item = _selectedImages[_selectedSubImageIndex!];
                    if (item.originalWidth != null) {
                      final s = _scaleOf(_selectedSubImageIndex!);
                      final cropW = item.originalWidth! / s;
                      final dispW_i = subRects[_selectedSubImageIndex!].width;
                      _selectedSrcToDispRatio = dispW_i > 0 ? cropW / dispW_i : 1.0;
                    }
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _onPreviewTap(d.localPosition, subRects),
                    child: SizedBox(
                    width: containerW,
                    height: containerH,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 图片（Listener 实现拖拽平移，绕过手势竞争）
                        Positioned(
                          left: left, top: top,
                          width: dispW, height: dispH,
                          child: Listener(
                            onPointerDown: (e) {
                              if (_selectedSubImageIndex != null) _panLastPos = e.localPosition;
                            },
                            onPointerMove: (e) {
                              if (_selectedSubImageIndex == null || _panLastPos == null) return;
                              final delta = e.localPosition - _panLastPos!;
                              _panLastPos = e.localPosition;
                              _onImagePanDelta(delta);
                            },
                            onPointerUp: (_) => _panLastPos = null,
                            onPointerCancel: (_) => _panLastPos = null,
                            child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: CustomPaint(
                              size: Size(dispW, dispH),
                              painter: _LivePreviewPainter(
                                images: [for (var e in _decodedThumbs) e!],
                                mode: _stitchMode,
                                scales: _imageScales,
                                offsets: _imageOffsets,
                                originalDims: [
                                  for (var item in _selectedImages)
                                    if (item.originalWidth != null && item.originalHeight != null)
                                      (width: item.originalWidth!, height: item.originalHeight!),
                                ],
                                addBorder: _borderPercent > 0,
                                borderColor: _borderUiColor,
                                borderPercent: _borderPercent,
                                rainbowBorder: _isRainbowBorder,
                              ),
                            ),
                          ),
                          ),
                        ),
                        // 工程图样式标注 - 填满容器以确保有空间画延伸线
                        if (_showRuler)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _DimensionPainter(
                                imageLeft: left, imageTop: top,
                                imageWidth: dispW, imageHeight: dispH,
                                displayWidth: _outputWidth!,
                                displayHeight: _outputHeight!,
                                strokeColor: Colors.white70,
                                textColor: Colors.white,
                                stitchMode: _stitchMode,
                                originalDims: [
                                  for (var item in _selectedImages)
                                    if (item.originalWidth != null && item.originalHeight != null)
                                      (width: item.originalWidth!, height: item.originalHeight!),
                                ],
                                borderPercent: _borderPercent,
                                selectedIndex: _selectedSubImageIndex,
                                imageScales: _imageScales,
                              ),
                            ),
                          ),
                        ),
                        // 选中子图的四个角点拖拽手柄
                        if (_selectedSubImageIndex != null &&
                            _selectedSubImageIndex! < subRects.length)
                          ..._buildCornerHandles(
                              subRects[_selectedSubImageIndex!]),
                      ],
                    ),
                    ),
                  );
                },
              ),
            ),
          )
        else
          _buildEmptyPreview(),
        // 保存进度覆盖层
        if (_saveProgress > 0)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 72, height: 72,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CircularProgressIndicator(strokeWidth: 5, value: _saveProgress, color: Colors.white, backgroundColor: Colors.white24),
                      Center(child: Text('${(_saveProgress * 100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text('正在保存...', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyPreview() {
    return Container(
      color: Colors.grey.shade100,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_outlined, size: 48, color: Colors.grey[350]),
          const SizedBox(height: 12),
          Text('选择图片后\n将在此显示预览',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey[400], height: 1.5)),
        ]),
      ),
    );
  }

  /// Android 平台：无卡片边框，预览居中全屏显示
  Widget _buildAndroidPreview() {
    return Stack(
      alignment: Alignment.center,
      children: [
        _canLivePreview
            ? InteractiveViewer(
                minScale: 0.15,
                maxScale: 8.0,
                boundaryMargin: const EdgeInsets.all(16),
                child: Center(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
                        return const SizedBox.shrink();
                      }
                      return SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        child: CustomPaint(
                          painter: _LivePreviewPainter(
                            images: [for (var e in _decodedThumbs) e!],
                            mode: _stitchMode,
                            scales: _imageScales,
                            offsets: _imageOffsets,
                            originalDims: [
                              for (var item in _selectedImages)
                                if (item.originalWidth != null && item.originalHeight != null)
                                  (width: item.originalWidth!, height: item.originalHeight!),
                            ],
                            addBorder: _borderPercent > 0,
                            borderColor: _borderUiColor,
                            borderPercent: _borderPercent,
                            rainbowBorder: _isRainbowBorder,
                          ),
                        ),
                      );
                    },
                  ),
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
              color: Colors.black54,
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 72, height: 72,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CircularProgressIndicator(strokeWidth: 5, value: _saveProgress, color: Colors.white, backgroundColor: Colors.white24),
                      Center(child: Text('${(_saveProgress * 100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text('正在保存...', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            ),
          ),
      ],
    );
  }

  // ========== 宽屏布局 ==========

  /// 宽屏：左侧三张功能卡片 + 右侧预览
  Widget _buildWideLayout() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧三张独立卡片
          SizedBox(
            width: 280,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildImageCard(),
                  const SizedBox(height: 12),
                  _buildModeCard(),
                  const SizedBox(height: 12),
                  _buildBorderCard(),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          // 右侧预览
          Expanded(child: _buildPreviewPanel()),
        ],
      ),
    );
  }

  // ---- 三张功能卡片（始终展开）----

  /// 选择图片卡片
  Widget _buildImageCard() {
    return _wideCard(
      icon: Icons.add_photo_alternate_outlined,
      title: '选择图片',
      subtitle: _selectedImages.isEmpty ? '未添加' : '已添加 ${_selectedImages.length} 张',
      onClear: _selectedImages.isNotEmpty ? () => setState(() { _selectedImages.clear(); _imageScales.clear(); _decodedThumbs.clear(); _imageOffsets.clear(); _selectedSubImageIndex = null; _outputWidth = null; _outputHeight = null; }) : null,
      child: _buildImageContentWide(),
    );
  }

  /// 拼接模式卡片
  Widget _buildModeCard() {
    final disabled = _selectedImages.length <= 1;
    return _wideCard(
      icon: Icons.settings_suggest,
      title: '拼接模式',
      subtitle: disabled ? '至少需要 2 张图' : (_stitchMode == StitchMode.horizontal ? '水平拼接' : '垂直拼接'),
      enabled: !disabled,
      child: _buildModeSubToolbar(),
    );
  }

  /// 边框卡片
  Widget _buildBorderCard() {
    return _wideCard(
      icon: Icons.border_style,
      title: '边框',
      subtitle: _borderPercent > 0
          ? '${_borderColorIndex == 0 ? "白色" : _borderColorIndex == 1 ? "黑色" : "彩虹"} · ${_borderPercent.toInt()}%'
          : '无边框',
      child: _buildBorderSubToolbar(),
    );
  }

  /// 通用宽屏卡片（始终展开）
  Widget _wideCard({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? child,
    VoidCallback? onClear,
    bool enabled = true,
  }) {
    final disabled = !enabled;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 卡片头部
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20,
                    color: disabled ? Colors.grey[400] : Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600,
                          color: disabled ? Colors.grey[400] : null)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(
                          fontSize: 11,
                          color: disabled ? Colors.grey[400] : Colors.grey[600])),
                    ],
                  ),
                ),
                if (onClear != null)
                  SizedBox(
                    width: 28, height: 28,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.delete_outline, size: 18, color: Colors.red[400]),
                      onPressed: onClear,
                    ),
                  ),
              ],
            ),
          ),
          // 内容区（始终可见）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: child ?? const SizedBox.shrink(),
          ),
        ],
      ),
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

  /// 子工具栏容器（窄屏用）
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: content,
    );
  }

  // --- 拼接模式子工具栏 ---
  Widget _buildModeSubToolbar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
      ),
    );
  }

  // --- 边框子工具栏 ---
  Widget _buildBorderSubToolbar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第一栏：颜色选择（横向可滚动，防止溢出卡片）
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
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
                    final scale = _imageScales.length > oldIndex ? _imageScales.removeAt(oldIndex) : 1.0;
                    final thumb = _decodedThumbs.length > oldIndex ? _decodedThumbs.removeAt(oldIndex) : null;
                    final offset = _imageOffsets.length > oldIndex ? _imageOffsets.removeAt(oldIndex) : Offset.zero;
                    _selectedImages.insert(newIndex, item);
                    _imageScales.insert(newIndex, scale);
                    _decodedThumbs.insert(newIndex, thumb);
                    _imageOffsets.insert(newIndex, offset);
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
                  key: ValueKey(item.path),
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
            _imageScales.removeAt(index);
            _decodedThumbs.removeAt(index);
            _imageOffsets.removeAt(index);
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
                      : Image.memory(item.bytes, fit: BoxFit.cover,
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
              // 尺寸标注
              if (item.originalWidth != null && item.originalHeight != null)
                Positioned(
                  bottom: 2, right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text('${item.originalWidth}×${item.originalHeight}',
                        style: const TextStyle(fontSize: 8, color: Colors.white70)),
                  ),
                ),
              // 删除遮罩
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() {
                      _selectedImages.removeAt(index);
                      _imageScales.removeAt(index);
                      _decodedThumbs.removeAt(index);
                      _imageOffsets.removeAt(index);
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

  // --- 宽屏选择图片瀑布流 ---

  Widget _buildImageContentWide() {
    final thumbnailCount = _selectedImages.length;

    // empty state
    if (thumbnailCount == 0) {
      return SizedBox(
        height: 48,
        child: ElevatedButton.icon(
          onPressed: _pickImages,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加图片'),
          style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 40)),
        ),
      );
    }

    // 2 列瀑布流，按原图比例计算高度
    const cols = 2;
    const gap = 6.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 添加按钮
        SizedBox(
          height: 40,
          child: OutlinedButton.icon(
            onPressed: _pickImages,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: const Text('继续添加', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 瀑布流缩略图（两列）
        LayoutBuilder(
          builder: (_, constraints) {
            final tileW = (constraints.maxWidth - gap) / cols;

            final tiles = <_TileData>[];
            for (var i = 0; i < thumbnailCount; i++) {
              final item = _selectedImages[i];
              final ar = (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0)
                  ? item.thumbWidth! / item.thumbHeight!
                  : 1.0;
              tiles.add(_TileData(index: i, height: tileW / ar));
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < cols; c++) ...[
                  if (c > 0) const SizedBox(width: gap),
                  Expanded(
                    child: Column(
                      children: [
                        for (var i = c; i < tiles.length; i += cols)
                          Padding(
                            padding: const EdgeInsets.only(bottom: gap),
                            child: _wideImageTile(tiles[i].index, tileW, tiles[i].height),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _wideImageTile(int index, double w, double h) {
    final item = _selectedImages[index];
    return GestureDetector(
      onTap: () => setState(() {
        _selectedImages.removeAt(index);
        _imageScales.removeAt(index);
        _decodedThumbs.removeAt(index);
        _imageOffsets.removeAt(index);
        _autoPreview();
      }),
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: Colors.grey[800],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            item.thumbnailBytes != null
                ? Image.memory(item.thumbnailBytes!, fit: BoxFit.cover)
                : Image.memory(item.bytes, fit: BoxFit.cover),
            // 序号角标
            Positioned(
              top: 2, left: 2,
              child: Container(
                width: 16, height: 16,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text('${index + 1}',
                    style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            // 尺寸标注
            if (item.originalWidth != null && item.originalHeight != null)
              Positioned(
                bottom: 2, right: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text('${item.originalWidth}×${item.originalHeight}',
                      style: const TextStyle(fontSize: 8, color: Colors.white70)),
                ),
              ),
            // 删除 X
            Positioned(
              top: 2, right: 2,
              child: Container(
                width: 16, height: 16,
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 10, color: Colors.white),
              ),
            ),
          ],
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
        _imageScales.clear();
        _decodedThumbs.clear();
        _imageOffsets.clear();
        _selectedSubImageIndex = null;
        _outputWidth = null;
        _outputHeight = null;
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
                          key: ValueKey('sheet_${item.path}'),
                          direction: DismissDirection.endToStart,
                          onDismissed: (_) {
                            setState(() { _selectedImages.removeAt(index); _imageScales.removeAt(index); _decodedThumbs.removeAt(index); _imageOffsets.removeAt(index); });
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
                              child: Image.memory(item.bytes, width: 44, height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _placeholderIcon()),
                            ),
                            title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1,
                                style: const TextStyle(fontSize: 13)),
                            subtitle: Text(
                              '#${index + 1}${item.originalWidth != null && item.originalHeight != null ? " · ${item.originalWidth}×${item.originalHeight}" : ""}',
                                style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600)),
                            trailing: IconButton(
                              iconSize: 18,
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                              onPressed: () {
                                setState(() { _selectedImages.removeAt(index); _imageScales.removeAt(index); _decodedThumbs.removeAt(index); _imageOffsets.removeAt(index); });
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
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        // Android/iOS: 使用原生图片选择器
        final results = await GalleryPickerScreen.pick(context);
        if (results == null || results.isEmpty) return;
        final tasks = <Future<void>>[];
        for (var picked in results) {
          final item = ImageItem(
            bytes: picked.bytes,
            path: picked.path,
            name: picked.name,
            originalWidth: picked.width,
            originalHeight: picked.height,
          );
          setState(() { _selectedImages.add(item); _imageScales.add(1.0); _decodedThumbs.add(null); _imageOffsets.add(Offset.zero); });
          tasks.add(_generateThumbnail(item));
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已添加 ${results.length} 张图片'),
            duration: const Duration(seconds: 1),
          ),
        );
        await Future.wait(tasks);
        if (_selectedImages.isNotEmpty) _autoPreview();
      } else {
        // 桌面 / Web：使用 file_picker
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp', 'gif'],
          allowMultiple: true,
          withData: true, // 始终请求 bytes 数据
        );
        if (result == null || result.files.isEmpty) return;
        final tasks = <Future<void>>[];
        for (var file in result.files) {
          // Web 上优先用 bytes，native 从文件读取
          Uint8List data;
          if (file.bytes != null) {
            data = file.bytes!;
          } else if (file.path != null) {
            data = await File(file.path!).readAsBytes();
          } else {
            continue;
          }
          final item = ImageItem(
            bytes: data,
            path: file.name,
            name: file.name,
          );
          setState(() { _selectedImages.add(item); _imageScales.add(1.0); _decodedThumbs.add(null); _imageOffsets.add(Offset.zero); });
          tasks.add(_generateThumbnail(item));
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加 ${result.files.length} 张图片'), duration: const Duration(seconds: 1)));
        await Future.wait(tasks);
        if (_selectedImages.isNotEmpty) _autoPreview();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择失败: $e')));
    }
  }

  Future<void> _generateThumbnail(ImageItem item) async {
    try {
      final thumb = await ImageStitcherService.createThumbnail(item.bytes, percent: 10);
      // 解码缩略图获取尺寸 + 缓存 ui.Image 供实时预览用
      final dims = await ImageStitcherService.getImageDimensions(thumb);
      final decoded = await _decodeUiImage(thumb);
      final idx = _selectedImages.indexOf(item);
      if (mounted) {
        setState(() {
          item.thumbnailBytes = thumb;
          if (dims != null) {
            item.thumbWidth = dims.width.toDouble();
            item.thumbHeight = dims.height.toDouble();
          }
          if (decoded != null && idx >= 0) {
            while (_decodedThumbs.length <= idx) _decodedThumbs.add(null);
            if (idx < _decodedThumbs.length) {
              _decodedThumbs[idx] = decoded;
            } else {
              _decodedThumbs.add(decoded);
            }
          }
        });
      }
      // 如果还没有原始尺寸（如 file_picker 路径），解码原图获取
      if (item.originalWidth == null || item.originalHeight == null) {
        final origDims = await ImageStitcherService.getImageDimensions(item.bytes);
        if (origDims != null && mounted) {
          setState(() {
            item.originalWidth = origDims.width;
            item.originalHeight = origDims.height;
          });
        }
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

  /// 预览更新：GPU 实时绘制，只需同步计算尺寸 + 触发重绘
  void _autoPreview() {
    if (_selectedImages.isEmpty) {
      setState(() { _outputWidth = null; _outputHeight = null; _selectedSubImageIndex = null; });
      return;
    }
    _calculateOutputDimensions();
    setState(() {}); // 触发 _LivePreviewPainter 重绘
  }

  /// 根据原始图片尺寸和边框设置，计算拼接后真正的输出尺寸（与 stitchImages 保存模式一致）
  void _calculateOutputDimensions() {
    // 需要所有图片都有原始尺寸
    for (var item in _selectedImages) {
      if (item.originalWidth == null || item.originalHeight == null) {
        _outputWidth = null;
        _outputHeight = null;
        return;
      }
    }

    final widths = _selectedImages.map((e) => e.originalWidth!).toList();
    final heights = _selectedImages.map((e) => e.originalHeight!).toList();

    int bw = 0;
    if (_borderPercent > 0) {
      final refDim = _stitchMode == StitchMode.horizontal
          ? heights.reduce((a, b) => a > b ? a : b)
          : widths.reduce((a, b) => a > b ? a : b);
      bw = (refDim * _borderPercent / 100).round().clamp(1, 9999);
    }

    if (_stitchMode == StitchMode.horizontal) {
      final maxH = heights.reduce((a, b) => a > b ? a : b);
      int totalW = 0;
      for (int i = 0; i < _selectedImages.length; i++) {
        totalW += (widths[i] * maxH / heights[i]).round();
      }
      _outputWidth = totalW + bw * (_selectedImages.length + 1);
      _outputHeight = maxH + 2 * bw;
    } else {
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      int totalH = 0;
      for (int i = 0; i < _selectedImages.length; i++) {
        totalH += (heights[i] * maxW / widths[i]).round();
      }
      _outputWidth = maxW + 2 * bw;
      _outputHeight = totalH + bw * (_selectedImages.length + 1);
    }
  }

  /// 解码 bytes 为 ui.Image（供实时预览用）
  Future<ui.Image?> _decodeUiImage(Uint8List bytes) async {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromList(bytes, (img) => completer.complete(img));
    return completer.future;
  }

  /// 计算每张子图在大预览中的显示矩形（用于点击检测）
  List<ui.Rect> _buildSubRects(double offsetX, double offsetY,
      double scaleX, double scaleY) {
    if (_selectedImages.length <= 1) return [];
    final rects = <ui.Rect>[];
    final n = _selectedImages.length;
    final widths = <int>[];
    final heights = <int>[];
    for (var item in _selectedImages) {
      widths.add(item.originalWidth ?? 0);
      heights.add(item.originalHeight ?? 0);
    }
    if (widths.contains(0)) return [];

    int bw = 0;
    if (_borderPercent > 0) {
      final refDim = _stitchMode == StitchMode.horizontal
          ? heights.reduce((a, b) => a > b ? a : b)
          : widths.reduce((a, b) => a > b ? a : b);
      bw = (refDim * _borderPercent / 100).round().clamp(1, 9999);
    }
    final bwDispX = bw * scaleX;
    final bwDispY = bw * scaleY;

    if (_stitchMode == StitchMode.horizontal) {
      final maxH = heights.reduce((a, b) => a > b ? a : b);
      double x = offsetX + bwDispX;
      for (int i = 0; i < n; i++) {
        final wDisp = (widths[i] * maxH / heights[i]) * scaleX;
        rects.add(ui.Rect.fromLTWH(x, offsetY + bwDispY, wDisp, maxH * scaleY));
        x += wDisp + bwDispX;
      }
    } else {
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      double y = offsetY + bwDispY;
      for (int i = 0; i < n; i++) {
        final hDisp = (heights[i] * maxW / widths[i]) * scaleY;
        rects.add(ui.Rect.fromLTWH(offsetX + bwDispX, y, maxW * scaleX, hDisp));
        y += hDisp + bwDispY;
      }
    }
    return rects;
  }

  /// 大预览图点击 → 选中对应子图
  void _onPreviewTap(Offset localPos, List<ui.Rect> subRects) {
    for (int i = 0; i < subRects.length; i++) {
      if (subRects[i].contains(localPos)) {
        setState(() {
          _selectedSubImageIndex = _selectedSubImageIndex == i ? null : i;
        });
        return;
      }
    }
    // 点到空白区域 → 取消选中
    setState(() => _selectedSubImageIndex = null);
  }

  /// 角点拖拽开始：记录初始状态
  void _onCornerDragStart(DragStartDetails details, int cornerIndex) {
    _dragCornerIndex = cornerIndex;
    _dragStartScale = _scaleOf(_selectedSubImageIndex ?? 0);
    _dragTotalDelta = Offset.zero;
  }

  /// 角点拖拽：沿中心缩放，比例不变
  void _onCornerDrag(DragUpdateDetails details) {
    if (_selectedSubImageIndex == null) return;
    final idx = _selectedSubImageIndex!;
    _dragTotalDelta += details.delta;

    // 四个角的外向方向（向外拖 = 放大）
    // 0=左上(-1,-1)  1=右上(+1,-1)  2=左下(-1,+1)  3=右下(+1,+1)
    const signs = [
      (-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0),
    ];
    final (sx, sy) = signs[_dragCornerIndex];
    // 将累计 delta 投影到外向对角线方向
    final outward = (_dragTotalDelta.dx * sx + _dragTotalDelta.dy * sy) / math.sqrt2;
    final change = outward / 200; // 200px 拖拽 ≈ 100% 缩放
    final newScale = (_dragStartScale + change).clamp(1.0, 3.0);
    final current = _scaleOf(idx);
    if ((newScale - current).abs() > 0.002) {
      setState(() {
        while (_imageScales.length <= idx) _imageScales.add(1.0);
        _imageScales[idx] = double.parse(newScale.toStringAsFixed(2));
      });
      _calculateOutputDimensions();
    }
  }

  /// 拖拽结束：GPU 实时预览已同步，无需额外处理
  void _onCornerDragEnd(DragEndDetails details) {}

  /// 选中子图拖拽：平移裁剪中心，限制在图片范围内
  void _onImagePanDelta(Offset displayDelta) {
    if (_selectedSubImageIndex == null) return;
    final idx = _selectedSubImageIndex!;
    final item = _selectedImages[idx];
    if (item.originalWidth == null || item.originalHeight == null) return;

    final s = _scaleOf(idx);
    if (s <= 1.0) return; // 未缩放时无法平移
    // 显示 delta → 源像素 delta（取反：向右拖图片向右移 = 裁剪中心向左移）
    final srcDelta = -displayDelta * _selectedSrcToDispRatio;
    while (_imageOffsets.length <= idx) _imageOffsets.add(Offset.zero);
    var newOffset = _imageOffsets[idx] + srcDelta;

    // 限制在图片范围内（裁剪区域不超出原图边界）
    final cropW = item.originalWidth! / s;
    final cropH = item.originalHeight! / s;
    final maxX = (item.originalWidth! - cropW) / 2;
    final maxY = (item.originalHeight! - cropH) / 2;
    newOffset = Offset(
      newOffset.dx.clamp(-maxX, maxX),
      newOffset.dy.clamp(-maxY, maxY),
    );

    if (newOffset != _imageOffsets[idx]) {
      setState(() => _imageOffsets[idx] = newOffset);
    }
  }

  /// 构建四个角点拖拽手柄
  List<Widget> _buildCornerHandles(ui.Rect r) {
    const double size = 14;
    const double half = size / 2;
    final corners = [
      Offset(r.left - half, r.top - half),
      Offset(r.right - half, r.top - half),
      Offset(r.left - half, r.bottom - half),
      Offset(r.right - half, r.bottom - half),
    ];
    final cursors = [
      SystemMouseCursors.resizeUpLeft,
      SystemMouseCursors.resizeUpRight,
      SystemMouseCursors.resizeDownLeft,
      SystemMouseCursors.resizeDownRight,
    ];
    return List.generate(4, (i) {
      return Positioned(
        left: corners[i].dx,
        top: corners[i].dy,
        width: size,
        height: size,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _onCornerDragStart(d, i),
          onPanUpdate: _onCornerDrag,
          onPanEnd: _onCornerDragEnd,
          child: MouseRegion(
            cursor: cursors[i],
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.blueAccent, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 2),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  void _startSaveTimer() {
    _stopSaveTimer();
    _saveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
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
        onProgress: (p) { _saveProgress = p; if (mounted) setState(() {}); },
        addBorder: _borderPercent > 0,
        borderColor: _borderUiColor,
        borderPercent: _borderPercent,
        rainbowBorder: _isRainbowBorder,
        scales: _imageScales,
        offsets: _imageOffsets,
      );
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await _saveToDeviceAlbum(fullResBytes);
      } else if (kIsWeb) {
        // Web: 触发浏览器下载
        final fileName = 'stitched_${_stitchMode == StitchMode.horizontal ? "H" : "V"}_${DateTime.now().millisecondsSinceEpoch}.png';
        await saveImage(fullResBytes, fileName);
        if (mounted) _showSaveSuccessDialog('已保存');
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
      setState(() { if (newIndex > oldIndex) newIndex--; final item = reordered.removeAt(oldIndex); reordered.insert(newIndex, item); _selectedImages.clear(); _imageScales.clear(); _decodedThumbs.clear(); _imageOffsets.clear(); _selectedImages.addAll(reordered); for (int i = 0; i < _selectedImages.length; i++) { _imageScales.add(1.0); _imageOffsets.add(Offset.zero); } }); _autoPreview();
    }, itemBuilder: (ctx, index) {
      final item = reordered[index];
      return ListTile(key: ValueKey(item.path), dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), leading: CircleAvatar(radius: 14, backgroundColor: Theme.of(ctx).colorScheme.primary, foregroundColor: Colors.white, child: Text('${index + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))), title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 13)), trailing: const Icon(Icons.drag_handle, color: Colors.grey, size: 20));
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

  Future<List<Uint8List>> _getSelectedImageBytes() async => [for (var item in _selectedImages) item.bytes];

}


/// 工程图风格的尺寸标注 Painter
/// 在图片四周绘制标注线、箭头和尺寸文字
class _DimensionPainter extends CustomPainter {
  final double imageLeft, imageTop, imageWidth, imageHeight;
  final int displayWidth, displayHeight;
  final Color strokeColor;
  final Color textColor;
  final StitchMode stitchMode;
  final List<({int width, int height})> originalDims;
  final double borderPercent;
  final int? selectedIndex;
  final List<double> imageScales;

  _DimensionPainter({
    required this.imageLeft,
    required this.imageTop,
    required this.imageWidth,
    required this.imageHeight,
    required this.displayWidth,
    required this.displayHeight,
    required this.strokeColor,
    required this.textColor,
    required this.stitchMode,
    required this.originalDims,
    required this.borderPercent,
    this.selectedIndex,
    this.imageScales = const [],
  });

  static const double _extensionGap = 12;  // 延伸线与图片边缘的间距
  static const double _extendLength = 18;  // 延伸线伸出长度
  static const double _arrowSize = 7;       // 箭头大小

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = strokeColor
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final imgLeft = imageLeft;
    final imgTop = imageTop;
    final imgRight = imageLeft + imageWidth;
    final imgBottom = imageTop + imageHeight;
    final scaleX = imageWidth / displayWidth;
    final scaleY = imageHeight / displayHeight;

    // ---------- 计算每张子图的显示区域 ----------
    final subRects = _computeSubRects(scaleX, scaleY, imgLeft, imgTop);

    // ---------- 选中高亮 ----------
    if (selectedIndex != null && selectedIndex! < subRects.length) {
      final sr = subRects[selectedIndex!];
      canvas.drawRect(
        sr,
        Paint()
          ..color = const ui.Color(0x444488FF)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        sr,
        Paint()
          ..color = const ui.Color(0xCC4488FF)
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );
      // 缩放百分比
      final sc = selectedIndex! < imageScales.length
          ? imageScales[selectedIndex!] : 1.0;
      if ((sc - 1.0).abs() > 0.01) {
        _drawDimTextTiny(canvas, '${(sc * 100).toInt()}%',
            Offset(sr.left + sr.width / 2, sr.top + sr.height / 2),
            TextAlign.center);
      }
    }

    // ---------- 总体标注：底部宽度 ----------
    final hExtLeft = imgLeft + _extensionGap;
    final hExtRight = imgRight - _extensionGap;
    final hLineY = imgBottom + _extendLength + 6;
    canvas.drawLine(Offset(imgLeft, imgBottom), Offset(imgLeft, hLineY), paint);
    canvas.drawLine(Offset(imgRight, imgBottom), Offset(imgRight, hLineY), paint);
    canvas.drawLine(Offset(hExtLeft, hLineY), Offset(hExtRight, hLineY), paint);
    _drawArrow(canvas, Offset(hExtLeft, hLineY), -1, paint);
    _drawArrow(canvas, Offset(hExtRight, hLineY), 1, paint);
    _drawDimText(canvas, '${displayWidth}px',
        Offset((hExtLeft + hExtRight) / 2, hLineY - 7),
        TextAlign.center);

    // ---------- 总体标注：右侧高度 ----------
    final vExtTop = imgTop + _extensionGap;
    final vExtBottom = imgBottom - _extensionGap;
    final vLineX = imgRight + _extendLength + 6;
    canvas.drawLine(Offset(imgRight, imgTop), Offset(vLineX, imgTop), paint);
    canvas.drawLine(Offset(imgRight, imgBottom), Offset(vLineX, imgBottom), paint);
    canvas.drawLine(Offset(vLineX, vExtTop), Offset(vLineX, vExtBottom), paint);
    _drawArrow(canvas, Offset(vLineX, vExtTop), -2, paint);
    _drawArrow(canvas, Offset(vLineX, vExtBottom), 2, paint);
    _drawDimText(canvas, '${displayHeight}px',
        Offset(vLineX + 7, (imgTop + imgBottom) / 2),
        TextAlign.left, rotate: false);

    // ---------- 每张图的独立标注：上边（宽度）+ 边框 ----------
    if (subRects.length > 1) {
      final perPaint = Paint()
        ..color = strokeColor.withValues(alpha: 0.45)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      final borderPaint = Paint()
        ..color = strokeColor.withValues(alpha: 0.3)
        ..strokeWidth = 0.5
        ..style = PaintingStyle.stroke;
      final topLineY = imgTop - _extendLength - 2;

      for (int i = 0; i < subRects.length; i++) {
        final r = subRects[i];
        final midX = r.left + r.width / 2;
        canvas.drawLine(Offset(midX, imgTop), Offset(midX, imgTop - 8), perPaint);
        _drawDimTextSmall(canvas, '${originalDims[i].width}',
            Offset(midX, topLineY), TextAlign.center);

        // 边框标注：每张图之间的间隙
        if (i < subRects.length - 1) {
          final gapLeft = r.right;
          final gapRight = subRects[i + 1].left;
          if (gapRight > gapLeft) {
            final gapMid = (gapLeft + gapRight) / 2;
            canvas.drawLine(Offset(gapLeft, imgTop), Offset(gapLeft, imgTop - 5), borderPaint);
            canvas.drawLine(Offset(gapRight, imgTop), Offset(gapRight, imgTop - 5), borderPaint);
            final bwPx = stitchMode == StitchMode.horizontal
                ? ((gapRight - gapLeft) / scaleX).round()
                : ((gapRight - gapLeft) / scaleY).round();
            _drawDimTextTiny(canvas, '↔$bwPx',
                Offset(gapMid, topLineY), TextAlign.center);
          }
        }
      }

      // ---------- 每张图的独立标注：左边（高度）+ 边框 ----------
      final leftLineX = imgLeft - _extendLength - 2;

      for (int i = 0; i < subRects.length; i++) {
        final r = subRects[i];
        final midY = r.top + r.height / 2;
        canvas.drawLine(Offset(imgLeft, midY), Offset(imgLeft - 8, midY), perPaint);
        _drawDimTextSmall(canvas, '${originalDims[i].height}',
            Offset(leftLineX, midY + 1), TextAlign.right);

        // 边框标注：每张图之间的间隙
        if (i < subRects.length - 1) {
          final gapTop = r.bottom;
          final gapBottom = subRects[i + 1].top;
          if (gapBottom > gapTop) {
            final gapMid = (gapTop + gapBottom) / 2;
            canvas.drawLine(Offset(imgLeft, gapTop), Offset(imgLeft - 5, gapTop), borderPaint);
            canvas.drawLine(Offset(imgLeft, gapBottom), Offset(imgLeft - 5, gapBottom), borderPaint);
            final bwPx = ((gapBottom - gapTop) / (stitchMode == StitchMode.horizontal ? scaleY : scaleX)).round();
            _drawDimTextTiny(canvas, '↕$bwPx',
                Offset(leftLineX - 14, gapMid), TextAlign.right);
          }
        }
      }
    }
  }

  /// 计算每张子图在显示屏上的矩形区域（含边框间距）
  List<ui.Rect> _computeSubRects(double scaleX, double scaleY,
      double offsetX, double offsetY) {
    if (originalDims.isEmpty) return [];
    final rects = <ui.Rect>[];
    final n = originalDims.length;
    final widths = originalDims.map((e) => e.width).toList();
    final heights = originalDims.map((e) => e.height).toList();

    int bw = 0; // border width in output pixels
    if (borderPercent > 0) {
      final refDim = stitchMode == StitchMode.horizontal
          ? heights.reduce((a, b) => a > b ? a : b)
          : widths.reduce((a, b) => a > b ? a : b);
      bw = (refDim * borderPercent / 100).round().clamp(1, 9999);
    }
    final bwDispX = bw * scaleX;
    final bwDispY = bw * scaleY;

    if (stitchMode == StitchMode.horizontal) {
      final maxH = heights.reduce((a, b) => a > b ? a : b);
      double x = offsetX + bwDispX;
      for (int i = 0; i < n; i++) {
        final wDisp = (widths[i] * maxH / heights[i]) * scaleX;
        rects.add(ui.Rect.fromLTWH(x, offsetY + bwDispY, wDisp, maxH * scaleY));
        x += wDisp + bwDispX;
      }
    } else {
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      double y = offsetY + bwDispY;
      for (int i = 0; i < n; i++) {
        final hDisp = (heights[i] * maxW / widths[i]) * scaleY;
        rects.add(ui.Rect.fromLTWH(offsetX + bwDispX, y, maxW * scaleX, hDisp));
        y += hDisp + bwDispY;
      }
    }
    return rects;
  }

  void _drawArrow(Canvas canvas, Offset tip, int direction, Paint paint) {
    // direction: -1=left, 1=right, -2=up, 2=down
    double dx1, dy1, dx2, dy2;
    if (direction == -1) {
      dx1 = _arrowSize; dy1 = -_arrowSize / 2; dx2 = _arrowSize; dy2 = _arrowSize / 2;
    } else if (direction == 1) {
      dx1 = -_arrowSize; dy1 = -_arrowSize / 2; dx2 = -_arrowSize; dy2 = _arrowSize / 2;
    } else if (direction == -2) {
      dx1 = -_arrowSize / 2; dy1 = _arrowSize; dx2 = _arrowSize / 2; dy2 = _arrowSize;
    } else {
      dx1 = -_arrowSize / 2; dy1 = -_arrowSize; dx2 = _arrowSize / 2; dy2 = -_arrowSize;
    }
    final fillPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + dx1, tip.dy + dy1)
      ..lineTo(tip.dx + dx2, tip.dy + dy2)
      ..close();
    canvas.drawPath(path, fillPaint);
  }

  void _drawDimText(Canvas canvas, String text, Offset center,
      TextAlign align, {bool rotate = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: 300);

    if (rotate) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(-math.pi / 2);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    } else {
      tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height));
    }
  }

  /// 小号文字（每张图的独立标注）
  void _drawDimTextSmall(Canvas canvas, String text, Offset center,
      TextAlign align) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor.withValues(alpha: 0.6),
          fontSize: 9,
          fontWeight: FontWeight.w500,
          fontFamily: 'monospace',
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: 200);

    // 半透明背景
    final bgPaint = Paint()
      ..color = const ui.Color(0x33000000)
      ..style = PaintingStyle.fill;
    final bgRect = ui.Rect.fromCenter(
      center: center, width: tp.width + 6, height: tp.height + 2,
    );
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(bgRect, const Radius.circular(3)),
      bgPaint,
    );

    final paintX = align == TextAlign.right
        ? center.dx - tp.width - 3
        : center.dx - tp.width / 2;
    tp.paint(canvas, Offset(paintX, center.dy - tp.height / 2));
  }

  /// 极小文字（边框宽度标注）
  void _drawDimTextTiny(Canvas canvas, String text, Offset center,
      TextAlign align) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor.withValues(alpha: 0.45),
          fontSize: 8,
          fontWeight: FontWeight.w400,
          fontFamily: 'monospace',
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: 160);

    final paintX = align == TextAlign.right
        ? center.dx - tp.width
        : center.dx - tp.width / 2;
    tp.paint(canvas, Offset(paintX, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _DimensionPainter oldDelegate) {
    return imageLeft != oldDelegate.imageLeft ||
        imageTop != oldDelegate.imageTop ||
        imageWidth != oldDelegate.imageWidth ||
        imageHeight != oldDelegate.imageHeight ||
        displayWidth != oldDelegate.displayWidth ||
        displayHeight != oldDelegate.displayHeight ||
        stitchMode != oldDelegate.stitchMode ||
        selectedIndex != oldDelegate.selectedIndex;
  }
}

/// 实时预览 Painter：拖拽时直接用 GPU 画布绘制，跳过 PNG 编解码
class _LivePreviewPainter extends CustomPainter {
  final List<ui.Image> images;
  final StitchMode mode;
  final List<double> scales;
  final List<Offset> offsets;
  final List<({int width, int height})> originalDims;
  final bool addBorder;
  final ui.Color borderColor;
  final double borderPercent;
  final bool rainbowBorder;

  _LivePreviewPainter({
    required this.images,
    required this.mode,
    required this.scales,
    required this.offsets,
    required this.originalDims,
    required this.addBorder,
    required this.borderColor,
    required this.borderPercent,
    required this.rainbowBorder,
  });

  /// 计算源裁剪区域（scale>1 时取中心 1/s 区域，offset 偏移裁剪中心）
  /// offset 以原图像素存储，需转换为缩略图像素
  ui.Rect _computeSrcRect(ui.Image src, double s, Offset offset, int origW, int origH) {
    if (s <= 1.0) {
      return ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
    }
    // 原图像素 → 缩略图像素
    final sx = src.width / origW;
    final sy = src.height / origH;
    final thumbOffset = Offset(offset.dx * sx, offset.dy * sy);
    final cw = src.width / s;
    final ch = src.height / s;
    final cx = src.width / 2 + thumbOffset.dx;
    final cy = src.height / 2 + thumbOffset.dy;
    return ui.Rect.fromLTWH(
      (cx - cw / 2).clamp(0.0, src.width - cw),
      (cy - ch / 2).clamp(0.0, src.height - ch),
      cw, ch,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (images.isEmpty) return;

    // 计算画布尺寸（与 stitchImages 一致，但不含 scale 对框的影响）
    int maxHeight = images.map((e) => e.height).reduce((a, b) => a > b ? a : b);
    int maxWidth = images.map((e) => e.width).reduce((a, b) => a > b ? a : b);
    int bw = 0;
    if (addBorder) {
      final ref = mode == StitchMode.horizontal ? maxHeight : maxWidth;
      bw = (ref * borderPercent / 100).round().clamp(1, 9999);
    }

    // 计算 dstRects + srcRects
    final dstRects = <ui.Rect>[];
    final srcRects = <ui.Rect>[];
    int canvasW, canvasH;

    if (mode == StitchMode.horizontal) {
      int totalW = 0;
      for (int i = 0; i < images.length; i++) {
        final src = images[i];
        final s = i < scales.length ? scales[i] : 1.0;
        final w = (src.width * maxHeight / src.height).round();
        dstRects.add(ui.Rect.fromLTWH(totalW.toDouble(), 0, w.toDouble(), maxHeight.toDouble()));
        final origW = i < originalDims.length ? originalDims[i].width : src.width;
        final origH = i < originalDims.length ? originalDims[i].height : src.height;
        srcRects.add(_computeSrcRect(src, s, i < offsets.length ? offsets[i] : Offset.zero, origW, origH));
        totalW += w;
      }
      canvasW = totalW + bw * (images.length + 1);
      canvasH = maxHeight + 2 * bw;
      if (addBorder) {
        double ox = bw.toDouble();
        for (int i = 0; i < dstRects.length; i++) {
          dstRects[i] = ui.Rect.fromLTWH(ox, bw.toDouble(), dstRects[i].width, dstRects[i].height);
          ox += dstRects[i].width + bw;
        }
      }
    } else {
      int totalH = 0;
      for (int i = 0; i < images.length; i++) {
        final src = images[i];
        final s = i < scales.length ? scales[i] : 1.0;
        final h = (src.height * maxWidth / src.width).round();
        dstRects.add(ui.Rect.fromLTWH(0, totalH.toDouble(), maxWidth.toDouble(), h.toDouble()));
        final origW2 = i < originalDims.length ? originalDims[i].width : src.width;
        final origH2 = i < originalDims.length ? originalDims[i].height : src.height;
        srcRects.add(_computeSrcRect(src, s, i < offsets.length ? offsets[i] : Offset.zero, origW2, origH2));
        totalH += h;
      }
      canvasW = maxWidth + 2 * bw;
      canvasH = totalH + bw * (images.length + 1);
      if (addBorder) {
        double oy = bw.toDouble();
        for (int i = 0; i < dstRects.length; i++) {
          dstRects[i] = ui.Rect.fromLTWH(bw.toDouble(), oy, dstRects[i].width, dstRects[i].height);
          oy += dstRects[i].height + bw;
        }
      }
    }

    // 缩放到画布显示区域（BoxFit.contain）
    final scaleX = size.width / canvasW;
    final scaleY = size.height / canvasH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final dispW = canvasW * scale;
    final dispH = canvasH * scale;
    final offX = (size.width - dispW) / 2;
    final offY = (size.height - dispH) / 2;

    canvas.save();
    canvas.translate(offX, offY);
    canvas.scale(scale);

    // 白色背景
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 边框 + 图片
    for (int i = 0; i < images.length; i++) {
      final dst = dstRects[i];
      if (addBorder) {
        final br = ui.Rect.fromLTWH(dst.left - bw, dst.top - bw, dst.width + 2 * bw, dst.height + 2 * bw);
        canvas.drawRect(br, ui.Paint()..color = borderColor);
      }
      canvas.drawImageRect(
        images[i],
        srcRects[i],
        dst,
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LivePreviewPainter oldDelegate) => true;
}
