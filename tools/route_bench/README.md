# route_bench

独立于 Flutter 插件的 FFmpeg 对照工具，用于生成软件编码、VideoToolbox、图片
编码基线，并对最终产物执行 ffprobe/VMAF。每次成功压缩都会在输出文件旁生成
`*.route.json` 机器可读报告，写入过程采用临时文件后再改名。

```bash
dart pub get
dart run bin/route_bench.dart doctor
dart run bin/route_bench.dart probe --input /absolute/input.mp4
dart run bin/route_bench.dart video --input /absolute/input.mp4 \
  --output /absolute/output.mp4 --route software --codec h264 \
  --bitrate 2000000 --remove-audio
dart run bin/route_bench.dart image --input /absolute/input.png \
  --output /absolute/output.jpg --format jpeg --quality 0.82
```

`vmaf` 子命令要求本机 FFmpeg 构建包含 `libvmaf`。工具是验证基础设施，不能作为
应用内分发 FFmpeg 的许可证结论。
