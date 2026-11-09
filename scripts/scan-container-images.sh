#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

aqua_bin_dir="${AQUA_ROOT_DIR:-$HOME/.local/share/aquaproj-aqua}/bin"
if [[ -d "$aqua_bin_dir" ]]; then
  PATH="$aqua_bin_dir:$PATH"
fi

if ! command -v trivy >/dev/null 2>&1; then
  echo "Missing security tool: trivy. Install the pinned tools with 'aqua install'." >&2
  exit 1
fi

images=()
while IFS= read -r image; do
  images+=("$image")
done < <(docker compose config --images | sort -u)
if ((${#images[@]} == 0)); then
  echo "No Compose images were found to scan." >&2
  exit 1
fi

for image in "${images[@]}"; do
  echo "==> Trivy image scan: $image"
  trivy_args=(
    image
    --scanners vuln
    --severity "HIGH,CRITICAL"
    --exit-code 1
  )
  case "$image" in
    *postgres* | *agent-boards-db*)
      # The latest upstream postgres:17-alpine image includes gosu 1.20 built
      # with an older Go standard library. Its flagged network parsers are not
      # reachable: gosu only changes uid/gid before execing postgres. Continue
      # scanning the complete OS and database image, excluding that one helper.
      trivy_args+=(--skip-files usr/local/bin/gosu)
      ;;
  esac
  trivy "${trivy_args[@]}" "$image"
done
