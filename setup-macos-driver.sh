#!/usr/bin/env bash
#
# setup-macos-driver.sh [install|uninstall]
#
# Installs the biosed/dell-1320c-cups-driver native filter chain (macOS
# arm64 build) locally and adds a CUPS queue pointed directly at the
# printer-proxy host, e.g.:
#
#   print client (this Mac)  ──renders PS → HBPL locally──►  socket://<proxy-host>:9100
#                                                                    │
#                                                              printer-proxy.py
#                                                            (power on, forward)
#
# Unlike routing through the Pi's driverless/AirPrint CUPS queue
# (setup-cups-driver.sh), this gives you the real vendor PPD locally, so
# FXColorMode (color/mono), tray selection, and page geometry all work
# correctly, and CUPS's own SNMP supply-level polling queries the proxy
# host directly (which snmp-responder.py answers) exactly as the rest of
# this project's design assumes.
#
# Requires Homebrew (for ghostscript) and PROXY_HOST to be set to the
# printer-proxy host's IP or hostname.
#
# Usage:
#   PROXY_HOST=192.168.11.10 ./setup-macos-driver.sh
#   ./setup-macos-driver.sh uninstall

set -euo pipefail

ACTION="${1:-install}"

DRIVER_VERSION="${DRIVER_VERSION:-v0.1.1}"
DRIVER_URL="${DRIVER_URL:-https://github.com/biosed/dell-1320c-cups-driver/releases/download/${DRIVER_VERSION}/dell-1320c-cups-driver-Darwin-arm64-${DRIVER_VERSION}.tar.gz}"

INSTALL_ROOT="/opt/Dell1320"
FILTER_DIR="${INSTALL_ROOT}/filter"
PPD_PATH="${INSTALL_ROOT}/Dell-1320c.ppd"

QUEUE_NAME="${QUEUE_NAME:-Dell1320c}"
PROXY_PORT="${PROXY_PORT:-9100}"

if [[ "$ACTION" == "uninstall" ]]; then
	echo "Removing CUPS queue '${QUEUE_NAME}'..."
	sudo lpadmin -x "$QUEUE_NAME" 2>/dev/null || true

	echo "Removing filters and PPD..."
	sudo rm -rf "$INSTALL_ROOT"

	echo "Done. Homebrew's ghostscript was left installed (remove with 'brew uninstall ghostscript' if unwanted)."
	exit 0
fi

if [[ "$ACTION" != "install" ]]; then
	echo "Usage: $0 [install|uninstall]" >&2
	exit 1
fi

if [[ -z "${PROXY_HOST:-}" ]]; then
	echo "Set PROXY_HOST to the printer-proxy host's IP or hostname, e.g.:" >&2
	echo "  PROXY_HOST=192.168.11.10 $0" >&2
	exit 1
fi

if ! command -v brew >/dev/null; then
	echo "Homebrew is required (for ghostscript). Install it from https://brew.sh and re-run." >&2
	exit 1
fi

echo "Installing Ghostscript via Homebrew..."
brew install ghostscript
GS_BINDIR="$(brew --prefix)/bin"

echo "Fetching driver ${DRIVER_VERSION} from ${DRIVER_URL}..."
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
curl -sL -o "${workdir}/driver.tar.gz" "$DRIVER_URL"
tar -xzf "${workdir}/driver.tar.gz" -C "$workdir"

srcdir="$(find "$workdir" -maxdepth 1 -type d -name 'dell-1320c-cups-driver-*')"
if [[ -z "$srcdir" ]]; then
	echo "Could not find extracted driver directory" >&2
	exit 1
fi

echo "Installing filters to ${FILTER_DIR}..."
sudo mkdir -p "$FILTER_DIR"
sudo install -m 755 "${srcdir}"/bin/* "$FILTER_DIR"/
sudo install -m 755 "${srcdir}"/scripts/* "$FILTER_DIR"/

# The upstream FXM_PS2PM wrapper hardcodes /usr/bin for `gs`, which doesn't
# exist on macOS (Homebrew installs to /opt/homebrew or /usr/local, and
# /usr/bin is SIP-protected so we can't symlink into it). Point it at
# Homebrew's gs instead.
sudo sed -i '' "s|^prefix=/usr\$|prefix=${GS_BINDIR%/bin}|" "${FILTER_DIR}/FXM_PS2PM"

# Apple Silicon requires at least an ad-hoc signature to execute a binary.
# Re-sign in case the release build didn't already carry one.
echo "Ad-hoc signing filter binaries..."
xattr -dr com.apple.quarantine "$FILTER_DIR" 2>/dev/null || true
for f in "$FILTER_DIR"/FXM_*; do
	codesign --force -s - "$f" 2>/dev/null || true
done

echo "Installing PPD to ${PPD_PATH}..."
sudo install -m 644 "${srcdir}/ppd/Dell-1320c.ppd" "$PPD_PATH"

echo "Adding CUPS queue '${QUEUE_NAME}' -> socket://${PROXY_HOST}:${PROXY_PORT}..."
sudo lpadmin -p "$QUEUE_NAME" -E \
	-v "socket://${PROXY_HOST}:${PROXY_PORT}" \
	-P "$PPD_PATH" \
	-o Option1=1Tray-S -o FXInputSlot=1stTray-S

lpoptions -d "$QUEUE_NAME"

cat <<EOF

Done. Queue '${QUEUE_NAME}' renders PostScript locally and sends already-
rendered HBPL bytes to printer-proxy.py at ${PROXY_HOST}:${PROXY_PORT}.

Open System Settings → Printers & Scanners → '${QUEUE_NAME}' → Options to
confirm FXColorMode/tray options are showing up.

To remove everything this script set up later, run:
  $0 uninstall
EOF
