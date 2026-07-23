#!/usr/bin/env bash
#
# setup-cups-driver.sh
#
# Installs CUPS + the biosed/dell-1320c-cups-driver native filter chain on
# this host, and adds a CUPS queue whose device URI points back at
# printer-proxy.py's own JetDirect listener (127.0.0.1:PROXY_PORT).
#
# This lets clients print PostScript/PDF via IPP to CUPS on this host,
# which renders it to the printer's native HBPL language, then hands the
# already-rendered bytes to printer-proxy.py exactly as a client with the
# Dell driver installed locally would have done. printer-proxy.py itself
# is unchanged: it still just powers the plug on and forwards raw bytes.
#
# Run as root (or with sudo) on the Debian/Ubuntu proxy host.

set -euo pipefail

DRIVER_VERSION="${DRIVER_VERSION:-v0.1.1}"
DRIVER_URL="${DRIVER_URL:-https://github.com/biosed/dell-1320c-cups-driver/releases/download/${DRIVER_VERSION}/dell-1320c-cups-driver-Linux-aarch64-${DRIVER_VERSION}.tar.gz}"

FILTER_DIR="/opt/Dell1320/filter"
PPD_DIR="/usr/share/ppd/Dell"
PPD_PATH="${PPD_DIR}/Dell-1320c.ppd"

QUEUE_NAME="${QUEUE_NAME:-Dell1320c}"
PROXY_PORT="${PROXY_PORT:-9100}"

if [[ $EUID -ne 0 ]]; then
	echo "Run this as root (sudo $0)" >&2
	exit 1
fi

echo "Installing CUPS, Ghostscript, and Avahi (for AirPrint discovery)..."
apt-get update
apt-get install -y cups ghostscript avahi-daemon
systemctl enable --now avahi-daemon

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
mkdir -p "$FILTER_DIR"
install -m 755 "${srcdir}"/bin/* "$FILTER_DIR"/
install -m 755 "${srcdir}"/scripts/* "$FILTER_DIR"/

echo "Installing PPD to ${PPD_PATH}..."
mkdir -p "$PPD_DIR"
install -m 644 "${srcdir}"/ppd/Dell-1320c.ppd "$PPD_PATH"

echo "Adding CUPS queue '${QUEUE_NAME}' -> socket://127.0.0.1:${PROXY_PORT}..."
lpadmin -p "$QUEUE_NAME" -E \
	-v "socket://127.0.0.1:${PROXY_PORT}" \
	-P "$PPD_PATH" \
	-o Option1=1Tray-S -o FXInputSlot=1stTray-S \
	-o printer-is-shared=true

lpoptions -d "$QUEUE_NAME"

cat <<EOF

Done. Queue '${QUEUE_NAME}' is set up to render PostScript/PDF locally and
hand off to printer-proxy.py on 127.0.0.1:${PROXY_PORT}.

Point clients at this host's IP via IPP (e.g. ipp://<proxy-host>/printers/${QUEUE_NAME})
using a generic PostScript driver — the Dell driver is no longer needed on
the client.

Avahi is running, so the queue should also show up automatically as an
AirPrint printer to iOS/macOS clients on the same LAN.
EOF
