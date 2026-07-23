#!/usr/bin/env bash
#
# setup-cups-driver.sh [install|uninstall]
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
# NOTE: driverless/AirPrint clients only see standard IPP attributes, so
# vendor-custom PPD options (color/mono, tray) and page geometry can be
# unreliable through this queue. If that's biting you, see
# setup-macos-driver.sh to render locally on a Mac instead — this script
# is left in place since it's still useful for other clients.
#
# Run as root (or with sudo) on the Debian/Ubuntu proxy host.
# Pass "uninstall" as the first argument to remove everything this script
# installed and revert cupsd.conf.

set -euo pipefail

ACTION="${1:-install}"

DRIVER_VERSION="${DRIVER_VERSION:-v0.1.1}"
DRIVER_URL="${DRIVER_URL:-https://github.com/biosed/dell-1320c-cups-driver/releases/download/${DRIVER_VERSION}/dell-1320c-cups-driver-Linux-aarch64-${DRIVER_VERSION}.tar.gz}"

FILTER_DIR="/opt/Dell1320/filter"
PPD_DIR="/usr/share/ppd/Dell"
PPD_PATH="${PPD_DIR}/Dell-1320c.ppd"

QUEUE_NAME="${QUEUE_NAME:-Dell1320c}"
PROXY_PORT="${PROXY_PORT:-9100}"

CUPSD_CONF="/etc/cups/cupsd.conf"
CUPSD_CONF_BACKUP="/etc/cups/cupsd.conf.printer-proxy.bak"

if [[ $EUID -ne 0 ]]; then
	echo "Run this as root (sudo $0)" >&2
	exit 1
fi

if [[ "$ACTION" == "uninstall" ]]; then
	echo "Removing CUPS queue '${QUEUE_NAME}'..."
	lpadmin -x "$QUEUE_NAME" 2>/dev/null || true

	echo "Reverting printer sharing..."
	cupsctl --no-share-printers --no-remote-any || true

	if [[ -f "$CUPSD_CONF_BACKUP" ]]; then
		echo "Restoring original ${CUPSD_CONF}..."
		mv "$CUPSD_CONF_BACKUP" "$CUPSD_CONF"
		systemctl restart cups
	else
		echo "No cupsd.conf backup found — leaving ${CUPSD_CONF} as-is." >&2
	fi

	echo "Removing filters and PPD..."
	rm -rf "$FILTER_DIR"
	rmdir --ignore-fail-on-non-empty "$(dirname "$FILTER_DIR")" 2>/dev/null || true
	rm -f "$PPD_PATH"
	rmdir --ignore-fail-on-non-empty "$PPD_DIR" 2>/dev/null || true

	if [[ "${PURGE_PACKAGES:-0}" == "1" ]]; then
		echo "Purging cups, ghostscript, avahi-daemon..."
		apt-get remove -y cups ghostscript avahi-daemon
	else
		echo "Leaving cups/ghostscript/avahi-daemon packages installed (set PURGE_PACKAGES=1 to remove)."
	fi

	echo "Done. Pi is clean of the CUPS driver setup."
	exit 0
fi

if [[ "$ACTION" != "install" ]]; then
	echo "Usage: $0 [install|uninstall]" >&2
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

echo "Opening CUPS to the LAN..."
cupsctl --share-printers --remote-any

if [[ ! -f "$CUPSD_CONF_BACKUP" ]]; then
	cp "$CUPSD_CONF" "$CUPSD_CONF_BACKUP"
fi
if grep -qE '^\s*Listen\s+localhost:631' "$CUPSD_CONF"; then
	sed -i 's/^\s*Listen\s\+localhost:631/Port 631/' "$CUPSD_CONF"
fi
if grep -qE '^\s*Listen\s+\[::1\]:631' "$CUPSD_CONF"; then
	sed -i '/^\s*Listen\s\+\[::1\]:631/d' "$CUPSD_CONF"
fi
systemctl restart cups

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
	echo "Opening firewall ports for IPP (631/tcp) and mDNS (5353/udp)..."
	ufw allow 631/tcp
	ufw allow 5353/udp
fi

cat <<EOF

Done. Queue '${QUEUE_NAME}' is set up to render PostScript/PDF locally and
hand off to printer-proxy.py on 127.0.0.1:${PROXY_PORT}.

Point clients at this host's IP via IPP (e.g. ipp://<proxy-host>/printers/${QUEUE_NAME})
using a generic PostScript driver — the Dell driver is no longer needed on
the client.

Avahi is running, so the queue should also show up automatically as an
AirPrint printer to iOS/macOS clients on the same LAN.

To remove everything this script set up later, run:
  sudo $0 uninstall
EOF
