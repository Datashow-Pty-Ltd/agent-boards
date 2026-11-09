#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# `aqua install` places command proxies here by default. Add the directory
# explicitly so a fresh checkout works even before the user configures Aqua in
# their interactive shell profile. CI's Aqua installer uses the same location.
aqua_bin_dir="${AQUA_ROOT_DIR:-$HOME/.local/share/aquaproj-aqua}/bin"
if [[ -d "$aqua_bin_dir" ]]; then
  PATH="$aqua_bin_dir:$PATH"
fi

required_tools=(trivy gitleaks osv-scanner shellcheck hadolint actionlint zizmor uvx)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing security tool: $tool. Install the pinned tools with 'aqua install'." >&2
    exit 1
  fi
done

echo "==> Trivy filesystem and configuration scan"
trivy filesystem \
  --scanners vuln,misconfig \
  --include-dev-deps \
  --ignorefile .trivyignore.yaml \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  .

echo "==> Gitleaks full-history scan"
gitleaks git --redact --no-banner --exit-code 1 .

echo "==> OSV-Scanner dependency scan"
osv-scanner scan source --lockfile pnpm-lock.yaml

echo "==> Semgrep Community Edition SAST"
uvx --from semgrep==1.184.0 semgrep scan \
  --config p/ci \
  --error \
  --metrics off \
  .

echo "==> ShellCheck"
shell_files=()
while IFS= read -r -d '' file; do
  shell_files+=("$file")
done < <(git ls-files -z '*.sh')
if ((${#shell_files[@]} > 0)); then
  shellcheck "${shell_files[@]}"
fi

echo "==> Hadolint"
container_files=()
while IFS= read -r -d '' file; do
  container_files+=("$file")
done < <(git ls-files -z 'docker/*.Containerfile')
if ((${#container_files[@]} > 0)); then
  hadolint "${container_files[@]}"
fi

echo "==> actionlint"
actionlint

echo "==> zizmor"
zizmor --min-severity medium .github/workflows

echo "==> Production dependency licence compatibility"
node scripts/check-licenses.mjs
