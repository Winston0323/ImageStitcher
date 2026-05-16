# 🖼️ Image Stitching - 图片拼接工具

一个基于 **Flutter** 开发的跨平台图片拼接应用，支持 **Windows** 和 **Android** 等多个平台。

## ✨ 功能特性

| 功能 | 说明 |
|------|------|
| **水平拼接** | 按宽度对齐，图片横向排列（统一高度） |
| **垂直拼接** | 按长度对齐，图片纵向排列（统一宽度） |
| **多图选择** | 支持一次选择多张图片进行拼接 |
| **顺序调整** | 可拖拽调整图片的拼接顺序 |
| **实时预览** | 拼接前可预览效果，支持缩放查看 |
| **自定义保存** | 自定义保存路径和文件名 |

## 🚀 快速开始

### 环境要求

1. **Flutter SDK** >= 3.0.0
2. 根据目标平台安装对应依赖：
   - Windows: 无需额外配置
   - Android: Android Studio + SDK
   - macOS: Xcode (可选)
   - Linux: 编译工具链

### 安装步骤

```bash
# 1. 进入项目目录
cd ImageStitching

# 2. 安装依赖
flutter pub get

# 3. 运行应用
# Windows:
flutter run -d windows

# Android (需要连接设备或模拟器):
flutter run -d android

# Web (浏览器):
flutter run -d chrome
```

## 📁 项目结构

```
ImageStitching/
├── lib/
│   ├── main.dart                    # 应用入口
│   ├── models/
│   │   └── image_item.dart          # 数据模型 (ImageItem, StitchMode)
│   ├── services/
│   │   └── image_stitcher_service.dart  # 拼接核心逻辑
│   └── screens/
│       └── home_screen.dart         # 主界面 UI
├── pubspec.yaml                     # 项目配置和依赖
└── README.md                        # 本文件
```

## 🔧 技术栈

- **UI框架**: Flutter 3.x (Material Design 3)
- **图片处理**: [image](https://pub.dev/packages/image) 库
- **文件选择**: [file_picker](https://pub.dev/packages/file_picker) 跨平台方案
- **状态管理**: Provider (可扩展)

## 🎨 使用说明

### 1. 选择拼接模式
- **水平拼接**: 所有图片按高度统一缩放后横向排列
- **垂直拼接**: 所有图片按宽度统一缩放后纵向排列

### 2. 添加图片
点击"添加图片"按钮，可以一次选择多张图片

### 3. 调整顺序（可选）
点击"调整顺序"，拖拽列表项改变图片的拼接顺序

### 4. 预览/保存
- 点击 **预览效果** 查看拼接结果
- 点击 **保存图片** 将结果保存到本地

## 📱 支持平台

| 平台 | 状态 | 备注 |
|------|------|------|
| Windows | ✅ 完全支持 | 原生桌面体验 |
| Android | ✅ 完全支持 | 移动端优化 |
| macOS | ✅ 支持 | 未专门优化 |
| Linux | ✅ 支持 | 未专门优化 |
| Web | ⚠️ 有限支持 | 文件保存受限 |

## 🛠️ 构建发布

### Windows 发布版
```bash
flutter build windows --release
```
输出: `build/windows/x64/runner/Release/`

### Android APK/AAB
```bash
flutter build apk --release        # APK格式
flutter build appbundle --release   # AAB格式 (Google Play)
```
输出: `build/app/outputs/...`

## 📝 开发计划

- [ ] 添加图片编辑功能（裁剪、旋转、滤镜）
- [ ] 批量处理模式
- [ ] 自定义间距设置
- [ ] 支持更多图片格式 (HEIC, AVIF, TIFF)
- [ ] 国际化多语言支持
- [ ] 深色模式自动切换

## 📄 许可证

MIT License

---

Made with ❤️ using Flutter
