#!/bin/sh
# Install img2text, or uninstall it if it is already installed.
#
#   curl -fsSL https://raw.githubusercontent.com/Jam-Sw/img2text/main/install.sh | sh
#
# Downloads the prebuilt command from the latest GitHub release into
# /usr/local/bin (on every Mac's PATH), asking for your password only if that
# folder needs it. Run from a checkout (`./install.sh`) it builds that checkout.
set -eu

REPO=${REPO:-https://github.com/Jam-Sw/img2text}
DOWNLOAD=${DOWNLOAD:-$REPO/releases/latest/download/img2text}
DEST=${PREFIX:-/usr/local/bin}

fail() { echo "img2text: $*" >&2; exit 1; }

# Run a command, with sudo only when DEST is not writable by us.
as_owner() {
    if [ -w "$DEST" ] || { [ ! -e "$DEST" ] && [ -w "$(dirname "$DEST")" ]; }; then "$@"
    else echo "(needs your password to write $DEST)"; sudo "$@"
    fi
}

# Piped through sh, stdin is this script; questions have to go to the terminal.
ask() {
    # -r /dev/tty can pass with no controlling terminal; only a real open proves one
    { : < /dev/tty; } 2>/dev/null || { echo "img2text is installed at $DEST/img2text; run in a terminal to uninstall."; return 1; }
    printf "%s [y/N] " "$1" > /dev/tty
    read -r reply < /dev/tty || return 1
    case $reply in [yY]*) return 0 ;; *) return 1 ;; esac
}

# Already installed? Offer to uninstall. Only ever remove our own binary.
if [ -e "$DEST/img2text" ]; then
    "$DEST/img2text" --help 2>&1 | grep -q -- "--gui" \
        || fail "$DEST/img2text exists but is not this tool; leaving it alone."
    if ask "img2text is installed at $DEST/img2text. Uninstall?"; then
        as_owner rm -f "$DEST/img2text"
        echo "Uninstalled."
    else
        echo "Left installed."
    fi
    exit 0
fi

[ "$(uname)" = Darwin ] || fail "macOS only (the app uses AppKit)."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

build() {  # $1 = source dir; prints the built binary's path
    command -v swift >/dev/null 2>&1 || fail "no prebuilt download, and Swift not found to build it. Install the command line tools: xcode-select --install"
    echo "Building from source (about a minute)…" >&2
    swift build --package-path "$1" -c release >/dev/null 2>&1 \
        || { swift build --package-path "$1" -c release >&2; fail "build failed (output above)"; }
    echo "$(swift build --package-path "$1" -c release --show-bin-path)/img2text"
}

here=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && grep -qs 'name: "img2text"' "$here/Package.swift"; then
    bin=$(build "$here")
elif echo "Downloading…" && curl -fsSL -o "$tmp/img2text" "$DOWNLOAD" \
        && chmod +x "$tmp/img2text" && "$tmp/img2text" --help 2>&1 | grep -q -- "--gui"; then
    bin=$tmp/img2text
else
    echo "No prebuilt release available; building from source instead." >&2
    command -v git >/dev/null 2>&1 || fail "git not found. Install the command line tools: xcode-select --install"
    git clone --quiet --depth 1 "$REPO.git" "$tmp/src" || fail "could not download $REPO"
    bin=$(build "$tmp/src")
fi

as_owner mkdir -p "$DEST"
as_owner install -m 755 "$bin" "$DEST/img2text"
echo "Installed. Run: img2text          (opens the app)"
echo "           or: img2text photo.png (prints it in the terminal)"
echo "Run this installer again to uninstall."
