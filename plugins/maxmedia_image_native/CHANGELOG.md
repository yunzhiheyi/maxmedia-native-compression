## 0.1.1

- Preserve a known non-sRGB RGB source ICC profile in Apple WebP output and
  verify the written profile, allowing wide-gamut photos to compress safely.

## 0.1.0

- Initial Android, iOS, and macOS native image compression support.
- JPEG, PNG, and WebP encoding; runtime-gated HEIC encoding on Apple platforms.
- Single and batch compression with progress, cancellation, and optional
  short-side-aware social resizing and two-pass quality adjustment.
- Re-export shared request, capability, and result contracts.
- Default color-space protection rejects outputs whose source profile cannot
  be verified as preserved; explicit conversion remains available.
