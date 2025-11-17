#!/usr/bin/env bash
set -euo pipefail

# Ensures the latest Tilt binary is available at infra/bin/tilt
# Strategy: try GitHub Releases; fallback to Homebrew on macOS.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"
BIN_DIR="$INFRA_DIR/bin"
TILT_BIN="${TILT_BIN:-$BIN_DIR/tilt}"

mkdir -p "$BIN_DIR"

need_install() {
  if [ ! -x "$TILT_BIN" ]; then
    return 0
  fi
  # If binary exists, compare with latest version tag; if different → install
  local current
  if ! current=$("$TILT_BIN" version | awk '{print $3}' | sed 's/^v//'); then
    return 0
  fi
  local latest
  if ! latest=$(curl -fsSL https://api.github.com/repos/tilt-dev/tilt/releases/latest | jq -r .tag_name | sed 's/^v//'); then
    # If we cannot fetch latest, keep existing
    return 1
  fi
  if [ "$current" != "$latest" ]; then
    return 0
  fi
  return 1
}

install_from_releases() {
  local os arch platform asset url tmp
  case "$(uname -s)" in
    Darwin) os="mac" ;;
    Linux) os="linux" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; return 1 ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac

  local json latest tag
  json=$(curl -fsSL https://api.github.com/repos/tilt-dev/tilt/releases/latest)
  tag=$(echo "$json" | jq -r .tag_name)
  asset="tilt.${tag}.${os}.${arch}.tar.gz"
  url=$(echo "$json" | jq -r --arg name "$asset" '.assets[] | select(.name==$name) | .browser_download_url')
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "Failed to find release asset for $asset" >&2
    return 1
  fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Tilt $tag ($os/$arch) ..." >&2
  curl -fsSL "$url" -o "$tmp/tilt.tgz"
  tar -xzf "$tmp/tilt.tgz" -C "$tmp" tilt
  install -m 0755 "$tmp/tilt" "$TILT_BIN"
  echo "Installed Tilt to $TILT_BIN" >&2
}

install_with_brew() {
  if command -v brew >/dev/null 2>&1; then
    echo "Installing/Upgrading Tilt via Homebrew ..." >&2
    (brew list tilt >/dev/null 2>&1 && brew upgrade tilt || brew install tilt) 1>&2
    # Point TILT_BIN to brewed binary if available
    local brewed
    brewed=$(command -v tilt || true)
    if [ -n "$brewed" ]; then
      ln -sf "$brewed" "$TILT_BIN"
      echo "Linked brewed Tilt to $TILT_BIN" >&2
      return 0
    fi
  fi
  return 1
}

if need_install; then
  echo "Ensuring latest Tilt is installed ..." >&2
  if ! install_from_releases; then
    echo "Release install failed, trying Homebrew ..." >&2
    install_with_brew || {
      echo "Failed to install Tilt automatically. Please install Tilt and retry." >&2
      exit 1
    }
  fi
else
  echo "Tilt is up-to-date at $TILT_BIN" >&2
fi

echo "$TILT_BIN"
