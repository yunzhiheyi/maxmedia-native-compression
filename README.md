# MaxMedia Route Lab

这是视频压缩与图片压缩技术路线的可运行验证工程，不是产品功能全集。

已发布到 pub.dev：
[media_route_contracts 0.1.0](https://pub.dev/packages/media_route_contracts)、
[maxmedia_image_native 0.1.0](https://pub.dev/packages/maxmedia_image_native)、
[maxmedia_video_native 0.1.0](https://pub.dev/packages/maxmedia_video_native)。
发布边界与尚未完成的 iPhone 真机保色验收见[发布记录](docs/PUB_RELEASE.md)。

## 目录

```text
apps/route_lab/                    Flutter 交互验证应用
packages/media_route_contracts/    版本化请求、能力和结果契约
plugins/maxmedia_image_native/     Android Bitmap / Apple ImageIO 图片路线
plugins/maxmedia_video_native/     Android Media3 / Apple AVAssetReader+Writer 视频路线
tools/route_bench/                 FFmpeg/VideoToolbox 基线、ffprobe 与 VMAF 工具
fixtures/                          公开样本 manifest；私有样本只保存在本机
benchmark_results/                 本机验证结果，不提交到公开仓库
docs/PUB_RELEASE.md                三个 pub.dev 包的发布检查清单
```

## 当前可执行范围

- 图片原生插件：JPEG/PNG/WebP；Apple 平台通过 libwebp 统一编码 WebP、按系统能力探测 HEIC，Android 同时支持 WebP。
- 视频原生插件 V0：H.264/HEVC、平均码率、GOP、真实进度、取消；目标码率会受源视频码率约束，输出未变小时删除无收益文件；Apple 和 Android 均接入按显示短边缩小，Apple 要求移除音频，两平台均保持源帧率。
- FFmpeg 基线：软件编码与 macOS VideoToolbox、图片 JPEG/PNG/WebP/AVIF、ffprobe、VMAF。
- Flutter Lab：查看设备能力、选择图片/视频并执行原生路线；单图可选 JPEG、PNG、WebP 和平台支持时的 HEIC，默认 WebP 80；批量图片可选择 JPEG/WebP/支持时的 HEIC 和分享尺寸，单视频及批量视频可选择分辨率与目标码率档位。完成后提供原文件/压缩后预览和结构化指标对比。

V0 会显式拒绝未实现能力，不静默降级。Apple 视频插件会回读输出的 codec、尺寸、帧率和容器估算数据率；最终路线结论仍必须使用 `route_bench probe` 和质量指标对输出独立复核。

## 快速验证

准备把三个独立包发布到 pub.dev 时，先看
[`docs/PUB_RELEASE.md`](docs/PUB_RELEASE.md) 的发布顺序、平台边界与校验步骤。

```bash
cd tools/route_bench
dart pub get
dart run bin/route_bench.dart doctor

dart run bin/route_bench.dart video \
  --input /absolute/input.mp4 \
  --output /absolute/output.mp4 \
  --route videotoolbox \
  --codec h264 \
  --bitrate 2000000 \
  --remove-audio

dart run bin/route_bench.dart image \
  --input /absolute/input.png \
  --output /absolute/output.jpg \
  --format jpeg \
  --quality 0.82
```

Flutter 桌面实验应用：

```bash
cd apps/route_lab
flutter pub get
flutter run -d macos
```

执行 Apple 原生图片与视频集成测试：

```bash
cd apps/route_lab
flutter test integration_test/native_routes_test.dart -d macos
```

发布前的验证门槛见 [`docs/PUB_RELEASE.md`](docs/PUB_RELEASE.md)。

源码采用 [BSD-3-Clause](LICENSE) 许可证；原生第三方依赖仍遵循各自许可证。
