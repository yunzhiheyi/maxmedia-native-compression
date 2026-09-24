#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
for plugin in maxmedia_image_native maxmedia_video_native; do
  cat > "$repo_root/plugins/$plugin/pubspec_overrides.yaml" <<'YAML'
dependency_overrides:
  media_route_contracts:
    path: ../../packages/media_route_contracts
YAML
  cat > "$repo_root/plugins/$plugin/example/pubspec_overrides.yaml" <<'YAML'
dependency_overrides:
  media_route_contracts:
    path: ../../../packages/media_route_contracts
YAML
done

echo 'Local plugin dependency overrides written (ignored by pub publish).'
