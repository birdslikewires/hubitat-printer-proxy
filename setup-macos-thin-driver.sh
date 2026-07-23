#!/usr/bin/env bash
#
# setup-macos-thin-driver.sh [install|uninstall]
#
# Installs just the Dell 1320c PPD locally (with its *cupsFilter /
# *FXMainFilter / *FXFilterDir / *FXFilterChain lines stripped out) and
# points the queue's device-uri at the Pi's existing CUPS queue over IPP:
#
#   print client (Mac)  ──IPP (plain PostScript)──►  ipp://<proxy-host>:631/printers/<remote queue>
#                                                              │
#                                                    CUPS on the Pi runs the
#                                                    real FXM_* filter chain
#                                                              │
#                                                              ▼
#                                                    socket://127.0.0.1:9100
#                                                              │
#                                                        printer-proxy.py
#                                                      (power on, forward)
#
# This gives macOS the real PPD for its print dialog (paper size,
# FXColorMode color/mono, tray) without needing any FXM_* filter binaries,
# Ghostscript, or codesigning locally — the Pi (set up via
# setup-cups-driver.sh) does the actual rendering, exactly as if a client
# there had submitted the job directly.
#
# IMPORTANT: do not also run setup-macos-driver.sh for the same queue name
# — that installs a *filtering* PPD locally, which would double-render the
# job (once locally, once again on the Pi) and corrupt the output. Pick one
# macOS approach: fully local (setup-macos-driver.sh) or thin/remote (this
# script).
#
# Requires setup-cups-driver.sh to have already been run on PROXY_HOST.
#
# Usage:
#   PROXY_HOST=192.168.11.10 ./setup-macos-thin-driver.sh
#   ./setup-macos-thin-driver.sh uninstall

set -euo pipefail

ACTION="${1:-install}"

DRIVER_VERSION="${DRIVER_VERSION:-v0.1.1}"
DRIVER_URL="${DRIVER_URL:-https://github.com/biosed/dell-1320c-cups-driver/releases/download/${DRIVER_VERSION}/dell-1320c-cups-driver-Linux-aarch64-${DRIVER_VERSION}.tar.gz}"

INSTALL_ROOT="/opt/Dell1320"
PPD_PATH="${INSTALL_ROOT}/Dell-1320c-thin.ppd"

QUEUE_NAME="${QUEUE_NAME:-Dell1320c}"
REMOTE_QUEUE="${REMOTE_QUEUE:-Dell1320c}"
IPP_PORT="${IPP_PORT:-631}"

if [[ "$ACTION" == "uninstall" ]]; then
	echo "Removing CUPS queue '${QUEUE_NAME}'..."
	sudo lpadmin -x "$QUEUE_NAME" 2>/dev/null || true
	sudo rm -f "$PPD_PATH"
	echo "Done."
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

echo "Fetching driver ${DRIVER_VERSION} PPD from ${DRIVER_URL}..."
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
curl -sL -o "${workdir}/driver.tar.gz" "$DRIVER_URL"
tar -xzf "${workdir}/driver.tar.gz" -C "$workdir"

srcdir="$(find "$workdir" -maxdepth 1 -type d -name 'dell-1320c-cups-driver-*')"
if [[ -z "$srcdir" ]]; then
	echo "Could not find extracted driver directory" >&2
	exit 1
fi

echo "Deriving filter-free PPD..."
sudo mkdir -p "$INSTALL_ROOT"
grep -vE '^\*(cupsFilter2?|FXMainFilter|FXFilterDir|FXFilterChain):' \
	"${srcdir}/ppd/Dell-1320c.ppd" | sudo tee "$PPD_PATH" >/dev/null

echo "Adding CUPS queue '${QUEUE_NAME}' -> ipp://${PROXY_HOST}:${IPP_PORT}/printers/${REMOTE_QUEUE}..."
sudo lpadmin -p "$QUEUE_NAME" -E \
	-v "ipp://${PROXY_HOST}:${IPP_PORT}/printers/${REMOTE_QUEUE}" \
	-P "$PPD_PATH" \
	-o Option1=1Tray-S -o FXInputSlot=1stTray-S

lpoptions -d "$QUEUE_NAME"

cat <<EOF

Done. Queue '${QUEUE_NAME}' presents the real Dell 1320c options locally
(paper size, FXColorMode, tray) but sends plain PostScript over IPP to the
Pi's '${REMOTE_QUEUE}' queue at ${PROXY_HOST}:${IPP_PORT}, which does the
actual FXM_* rendering and forwards to printer-proxy.py.

Open System Settings → Printers & Scanners → '${QUEUE_NAME}' → Options to
confirm FXColorMode/tray options are showing up, and print a test page to
confirm output looks right end to end.

To remove it later: $0 uninstall
EOF
