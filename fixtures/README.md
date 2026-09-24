# 验证样本

公开仓库只保存样本 manifest、授权说明和 SHA-256，不直接提交未获授权的用户媒体。

建议目录：

```text
fixtures/
  manifest.json
  private/         # 本机样本，已在根 .gitignore 中排除
```

每个样本至少登记 `sample_id`、授权来源、SHA-256、容器/codec、尺寸、帧率、HDR/VFR、音轨和必须保留的语义字段。
