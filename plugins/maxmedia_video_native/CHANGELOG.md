## 0.1.0

- Initial Android Media3 and iOS/macOS AVFoundation video compression support.
- H.264 and HEVC, bitrate and GOP controls, progress, cancellation, and
  aspect-ratio-preserving short-side downscaling.
- Reject outputs that are not smaller than their sources.
- iOS photo-library source selection and explicit Apple HDR handling policies.
- Default HDR protection keeps detected HDR sources unchanged rather than
  silently producing an unverified SDR or 8-bit export.
- Re-export shared request, capability, and result contracts.
