# hubitat-printer-proxy

A lightweight TCP proxy that sits between your network and a printer on a smart plug controlled via the Hubitat Maker API, powering it on automatically when a print job arrives, and keeping the client happy about printer status by providing SNMP responses when it's off.

## How It Works

```
print client
        │
        │  port 9100 (JetDirect)
        ▼
  printer-proxy        ──→  Hubitat API  ──→  smart plug (power on)
        │
        │  port 9100 (JetDirect, with retry)
        ▼
     Printer
```

1. **Print job arrives** on port 9100 at the proxy host.
2. **Proxy calls the Hubitat API** to power on the printer's smart plug.
3. **Proxy retries the printer connection** until the printer is online (up to ~30 seconds).
4. **TCP stream is forwarded transparently** in both directions — the print client sees a normal JetDirect connection.
5. **After the job completes**, the proxy walks the printer's SNMP and caches supply/status data to disk.
6. **Power-off** is handled by a Hubitat automation watching the plug's wattage — when it drops to idle, the plug turns off.

When the printer is off, `snmp-responder.py` serves the cached SNMP data back to the client via `snmpd pass_persist`, so the print queue shows ink levels and a plausible status rather than an error.

## Components

| File | Purpose |
|------|---------|
| `printer-proxy.py` | TCP proxy / power-on trigger |
| `snmp-responder.py` | `snmpd pass_persist` script serving cached printer MIB data |
| `printer-proxy.service` | systemd unit for the proxy (runs on a Linux host) |
| `printer-proxy-snmp.conf` | Drop-in snmpd config to wire up the pass_persist handler |

## Requirements

- Linux host on the same network as the printer with Python 3.9+
- Packges `snmpwalk` / `snmpd` (from `net-snmp` package)
- Printer with a JetDirect (port 9100) interface and SNMP support
- A [Hubitat](https://hubitat.com) hub with the printer's smart plug added as a device
- Clients configured to print via the proxy host's IP

## Setup

### 1. Configure the proxy

Edit `printer-proxy.py` and set the values in the `# --- Configuration ---` block:

```python
PRINTER_HOST   = "192.168.x.x"   # printer's IP
HUBITAT_HOST   = "192.168.x.x"   # Hubitat hub's IP
HUBITAT_APP    = "101"            # Maker API app ID
HUBITAT_TOKEN  = "your-token"    # Maker API access token
HUBITAT_DEVICE = "224"           # device ID of the smart plug
```

### 2. Install the proxy

```bash
sudo mkdir -p /usr/local/lib/printer-proxy /opt/printer-proxy
sudo cp printer-proxy.py /usr/local/lib/printer-proxy/
sudo cp snmp-responder.py /opt/printer-proxy/
```

### 3. Install and start the systemd service

```bash
sudo cp printer-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now printer-proxy
```

### 4. Configure snmpd

```bash
sudo cp printer-proxy-snmp.conf /etc/snmp/snmpd.conf.d/
sudo systemctl restart snmpd
```

Edit `printer-proxy-snmp.conf` and update the `rocommunity` line to match your local subnet (the file contains `192.168.11.0/24` as an example).

`snmpd` only listens on loopback by default. Edit `/etc/snmp/snmpd.conf` and add your host's LAN IP to the `agentaddress` line so clients can reach it:

```
agentaddress 127.0.0.1,[::1],192.168.x.x
```

### 5. Point client at the proxy

For macOS, in **System Settings → Printers & Scanners**, add the printer using the proxy host's IP address and **HP Jetdirect – Socket** protocol on port 9100. Select your printer's PPD/driver as normal.

## SNMP data served

The responder caches and serves the following MIB subtrees from the printer:

| OID | Description |
|-----|-------------|
| `1.3.6.1.2.1.43.5.1.1` | Printer general info |
| `1.3.6.1.2.1.43.7.1.1` | Input trays |
| `1.3.6.1.2.1.43.11.1.1` | Supply levels (ink/toner) |
| `1.3.6.1.2.1.43.12.1.1` | Media types |
| `1.3.6.1.2.1.25.3.5.1.2.1` | Printer status (served as "idle" when off) |

## Hubitat setup

Enable the **Maker API** app on your Hubitat hub and add the smart plug device to it. The proxy uses the `on` command — power-off should be handled by a separate automation (e.g. a Rule that watches the plug's power reporting and turns off after wattage drops below idle for N seconds).

## Logs

```bash
journalctl -u printer-proxy -f
```
