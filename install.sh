#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/aberhamm/cctrl.git"
INSTALL_DIR="${CCTRL_DIR:-$HOME/.local/share/cctrl}"
BIN_DIR="${HOME}/.local/bin"

GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { echo -e "${GREEN}$1${RESET}"; }
dim()   { echo -e "${DIM}$1${RESET}"; }

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
    dim "Updating existing install at $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only
else
    dim "Cloning cctrl to $INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR"
fi

# Symlink binary
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/cctrl" "$BIN_DIR/cctrl"
chmod +x "$INSTALL_DIR/cctrl"

# Ensure ~/.local/bin is in PATH
add_to_path() {
    local file="$1"
    if [ -f "$file" ] && grep -q '.local/bin' "$file" 2>/dev/null; then
        return
    fi
    echo '' >> "$file"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$file"
    dim "Added ~/.local/bin to PATH in $(basename "$file")"
}

if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
        add_to_path "$HOME/.zprofile"
    else
        add_to_path "$HOME/.profile"
    fi
fi

# Zsh completions
if [ "$(basename "$SHELL")" = "zsh" ]; then
    COMP_DIR="${HOME}/.local/share/zsh/site-functions"
    mkdir -p "$COMP_DIR"
    ln -sf "$INSTALL_DIR/completions/_cctrl" "$COMP_DIR/_cctrl"

    # Add to fpath if not already present
    ZSHRC="${HOME}/.zshrc"
    if [ -f "$ZSHRC" ] && ! grep -q 'site-functions' "$ZSHRC" 2>/dev/null; then
        echo '' >> "$ZSHRC"
        echo 'fpath=(~/.local/share/zsh/site-functions $fpath)' >> "$ZSHRC"
        echo 'autoload -Uz compinit && compinit' >> "$ZSHRC"
        dim "Added zsh completions to .zshrc"
    fi
fi

echo ""
info "✓ cctrl installed"
dim "  Binary:      $BIN_DIR/cctrl"
dim "  Source:       $INSTALL_DIR"
dim "  Update:       cctrl itself or re-run this script"
echo ""

if ! command -v cctrl &>/dev/null; then
    echo -e "${BOLD}Restart your shell or run:${RESET}  source ~/.zprofile"
fi
