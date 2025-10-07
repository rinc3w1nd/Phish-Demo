#!/usr/bin/env bash
# bootstrap-mbp-lab.sh
# Prepare an MBP host for the UTM lab.
# - Installs Xcode CLI tools (if needed)
# - Installs Homebrew (if missing)
# - Installs brew packages: python@3.11, qemu, cdrtools, coreutils
# - Installs Python packages into user site: requests, beautifulsoup4, tqdm
#
# Usage:
#   chmod +x bootstrap-mbp-lab.sh
#   ./bootstrap-mbp-lab.sh
#
# Notes:
# - On first run Xcode CLI installer will pop a GUI dialog; follow the prompts.
# - The script will wait for Xcode CLI Tools to be installed before continuing.
# - The script will persist 'eval "$(brew shellenv)"' to your shell profile if necessary.
set -euo pipefail

# Config
BREW_PKGS=(python@3.11 qemu cdrtools coreutils)
PY_PKGS=(requests beautifulsoup4 tqdm)
SCRIPT_NAME="$(basename "$0")"

# Helpers
echo_header() { printf "\n==== %s ====\n" "$*"; }
echoinfo() { printf " - %s\n" "$*"; }
echowarn() { printf " ! %s\n" "$*"; }
echoerr() { printf "\nERROR: %s\n\n" "$*" >&2; }

# 1) Xcode Command Line Tools
ensure_xcode_cli() {
  echo_header "Checking Xcode Command Line Tools"
  if xcode-select -p >/dev/null 2>&1; then
    echoinfo "Xcode CLI tools present: $(xcode-select -p)"
    return 0
  fi

  echoinfo "Xcode CLI tools not found. Requesting install..."
  # This triggers Apple's GUI installer. It's safe to call repeatedly.
  if ! xcode-select --install >/dev/null 2>&1; then
    echowarn "xcode-select --install returned nonzero; installer may already be queued."
  fi

  echoinfo "Waiting for Xcode Command Line Tools to be available. This may require you to click through a GUI dialog."
  # Poll for install completion
  SECONDS_WAITED=0
  while ! xcode-select -p >/dev/null 2>&1; do
    if (( SECONDS_WAITED % 10 == 0 )); then
      echowarn "Still waiting for Xcode CLI tools to finish installing... (waited ${SECONDS_WAITED}s)."
      echoinfo "If the installer GUI is open, accept/install. If it completed already, run this script again."
    fi
    sleep 5
    SECONDS_WAITED=$(( SECONDS_WAITED + 5 ))
    # After a large timeout, remind user how to check
    if (( SECONDS_WAITED > 600 )); then
      echoerr "Xcode CLI tools installation is taking a long time (>10m). Please ensure the GUI installer has completed, then re-run the script."
      exit 2
    fi
  done
  echoinfo "Xcode CLI tools installed."
}

# 2) Homebrew
ensure_homebrew() {
  echo_header "Ensuring Homebrew is installed"
  if command -v brew >/dev/null 2>&1; then
    echoinfo "Homebrew already installed at: $(command -v brew)"
  else
    echoinfo "Homebrew not found — installing..."
    # Official installer; safe to run as script
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echoinfo "Homebrew install finished (check output above for any prompts)."
  fi

  # Put brew on PATH for current shell
  BREW_PREFIX=""
  if [[ -d "/opt/homebrew" ]]; then
    BREW_PREFIX="/opt/homebrew"
  elif [[ -d "/usr/local" ]]; then
    BREW_PREFIX="$(/usr/local/bin/brew --prefix 2>/dev/null || true)"
  fi

  if [[ -z "$BREW_PREFIX" ]]; then
    # Try asking brew for prefix
    if command -v brew >/dev/null 2>&1; then
      BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$BREW_PREFIX" ]]; then
    eval "$("$BREW_PREFIX/bin/brew" shellenv 2>/dev/null || true)" || true
  else
    # Fallback
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
  fi

  # Persist brew shellenv to shell profile if not present
  detect_and_persist_brew_shellenv
}

detect_and_persist_brew_shellenv() {
  # Determine user's login shell rc file to persist brew env
  local user_shell
  user_shell="$(basename "${SHELL:-/bin/zsh}")"
  local profile_file

  case "$user_shell" in
    zsh) profile_file="${HOME}/.zprofile" ;;
    bash) profile_file="${HOME}/.bash_profile" ;;
    ksh) profile_file="${HOME}/.profile" ;;
    *) profile_file="${HOME}/.profile" ;;
  esac

  # Line to persist
  local persist_line='eval "$($(brew --prefix)/bin/brew shellenv)"'
  # Simpler canonical form that works across prefixes:
  local brew_eval='eval "$($(brew --prefix 2>/dev/null || true)/bin/brew shellenv)"'

  # Use brew's recommended one
  local brew_line='eval "$($(brew --prefix)/bin/brew shellenv)"'
  # Simpler: use `eval "$(/opt/homebrew/bin/brew shellenv)"` if that exists.
  local simpler_line='eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"'

  # If profile doesn't exist, create it
  if [[ ! -f "$profile_file" ]]; then
    echoinfo "Creating shell profile: $profile_file"
    printf "%s\n" "# Created by $SCRIPT_NAME to persist Homebrew environment" >"$profile_file"
  fi

  # Ensure brew eval is present (naive but safe)
  if ! grep -F "brew shellenv" "$profile_file" >/dev/null 2>&1; then
    echoinfo "Persisting Homebrew setup to $profile_file"
    # append the safe eval snippet
    {
      printf "\n# Homebrew environment (added by %s)\n" "$SCRIPT_NAME"
      printf "%s\n" 'if command -v brew >/dev/null 2>&1; then'
      printf "  %s\n" '  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"'
      printf "%s\n" 'fi'
    } >>"$profile_file"
    echoinfo "Appended brew shellenv to $profile_file"
  else
    echoinfo "Homebrew environment already persisted in $profile_file"
  fi
}

# 3) Brew install packages
brew_install_pkgs() {
  echo_header "Installing Homebrew packages"
  # Update once
  echoinfo "Updating Homebrew..."
  brew update --quiet || echowarn "brew update had non-fatal issues."

  local to_install=()
  for pkg in "${BREW_PKGS[@]}"; do
    if brew list --formula | grep -x "$pkg" >/dev/null 2>&1; then
      echoinfo "Package already installed: $pkg"
    else
      to_install+=("$pkg")
    fi
  done

  if [[ ${#to_install[@]} -gt 0 ]]; then
    echoinfo "Installing: ${to_install[*]}"
    brew install "${to_install[@]}"
  else
    echoinfo "All requested brew packages already installed."
  fi
}

# 4) Python packages into user site
pip_install_user_pkgs() {
  echo_header "Installing Python packages to user site"
  # Prefer brew python if available
  # Use python3 -m pip
  if ! command -v python3 >/dev/null 2>&1; then
    echoerr "python3 not found after brew install. Please ensure Homebrew's python is on PATH and re-run."
    exit 3
  fi

  # Upgrade pip in user site
  echoinfo "Upgrading pip (user) and installing packages: ${PY_PKGS[*]}"
  python3 -m pip install --upgrade --user pip setuptools wheel
  python3 -m pip install --user "${PY_PKGS[@]}"
}

# 5) Quick sanity checks and output
post_checks() {
  echo_header "Post-installation status"

  echoinfo "Python:"
  python3 --version 2>/dev/null || echowarn "python3 not found"

  echoinfo "pip:"
  pip3 --version 2>/dev/null || echowarn "pip3 not found"

  echoinfo "genisoimage (cdrtools):"
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -version 2>/dev/null || echoinfo "genisoimage present"
  elif command -v mkisofs >/dev/null 2>&1; then
    echoinfo "mkisofs present"
  else
    echowarn "genisoimage/mkisofs not in PATH (cdrtools may have installed as mkisofs)."
  fi

  echoinfo "qemu:"
  if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    qemu-system-aarch64 --version 2>/dev/null || echoinfo "qemu present"
  elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
    qemu-system-x86_64 --version 2>/dev/null || echoinfo "qemu present"
  else
    echowarn "qemu not found in PATH"
  fi

  echoinfo "coreutils (GNU):"
  if command -v gsha256sum >/dev/null 2>&1; then
    echoinfo "gsha256sum present"
  else
    echowarn "coreutils installed; GNU tools are available with 'g' prefix (e.g., gsha256sum)."
  fi

  echoinfo "Python libs:"
  python3 - <<'PY' || true
import importlib, sys
libs = ['requests','bs4','tqdm']
for l in libs:
    try:
        importlib.import_module(l)
        print(f" - {l}: OK")
    except Exception as e:
        print(f" - {l}: MISSING ({e})")
PY

  echo_header "Done"
  printf "Next steps:\n"
  printf " - Open a new terminal (or source your profile) so Homebrew is on PATH, e.g.:\n"
  printf "     eval \"\$($(brew --prefix 2>/dev/null || true)/bin/brew shellenv)\"\n"
  printf " - Build your cloud-init ISOs (use build-cidata.sh), download UTM templates, and continue lab setup.\n\n"
}

# -------- main --------
main() {
  echo_header "Bootstrapping MBP for UTM lab"

  ensure_xcode_cli
  ensure_homebrew
  brew_install_pkgs
  pip_install_user_pkgs
  post_checks

  echo_header "Bootstrap complete"
}
main "$@"
