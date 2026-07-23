# hubitat-printer-proxy

Lightweight TCP proxy that sits between your client and a printer on a smart plug controlled via the Hubitat Maker API. The printer is powered on automatically when a print job arrives, and we keep the client happy about printer status by providing SNMP responses when the printer is powered off.

Optionally, a CUPS queue on the same host (using the [biosed/dell-1320c-cups-driver](https://github.com/biosed/dell-1320c-cups-driver) native filter chain) can render PostScript/PDF to the printer's HBPL language locally, so clients no longer need the Dell driver installed themselves — see [Optional: render on the proxy host](#optional-render-on-the-proxy-host-instead-of-the-client).

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
6. **Power-off** is handled by a Hubitat automation watching the plug's wattage — when it drops to idle, the plug turns off after a twenty-minute timeout. You'll need to configure this automation yourself on Hubitat.

When the printer is off, `snmp-responder.py` serves the cached SNMP data back to the client via `snmpd pass_persist`, so the print queue shows ink levels and a plausible status rather than an error.

The proxy itself never inspects or renders the print data — the bytes it forwards on port 9100 are already in the printer's native language. Normally that rendering happens on the client (e.g. macOS's own Dell driver). The optional CUPS setup below moves that rendering step onto the proxy host instead, ahead of `printer-proxy.py`'s listener.

## Components

| File | Purpose |
|------|---------|
| `printer-proxy.py` | TCP proxy / power-on trigger |
| `snmp-responder.py` | `snmpd pass_persist` script serving cached printer MIB data |
| `printer-proxy.service` | systemd unit for the proxy (runs on a Linux host) |
| `printer-proxy-snmp.conf` | Drop-in snmpd config to wire up the pass_persist handler |
| `setup-cups-driver.sh` | Optional: installs CUPS + the Dell 1320c native filter chain, pointed at the proxy's own listener |

## Requirements

- Linux host on the same network as the printer with Python 3.9+
- Packges `snmpwalk` / `snmpd` (from `net-snmp` package)
- Printer with a JetDirect (port 9100) interface and SNMP support
- A [Hubitat](https://hubitat.com) hub with the printer's smart plug added as a device
- Clients configured to print via the proxy host's IP

## Setup

### 1. Clone the repo

```bash
sudo git clone https://github.com/birdslikewires/hubitat-printer-proxy /opt/hubitat-printer-proxy
sudo chown -R $USER:$USER /opt/hubitat-printer-proxy
```

To update later: `cd /opt/hubitat-printer-proxy && git pull`

### 2. Configure

```bash
sudo cp /opt/hubitat-printer-proxy/printer-proxy.env.example /opt/hubitat-printer-proxy/printer-proxy.env
sudo nano /opt/hubitat-printer-proxy/printer-proxy.env
```

Set your printer's IP, Hubitat hub IP, Maker API app ID, access token, and device ID. Restrict permissions to keep the token private:

```bash
chmod 600 /opt/hubitat-printer-proxy/printer-proxy.env
```

### 3. Install and start the systemd service

```bash
sudo cp /opt/hubitat-printer-proxy/printer-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now printer-proxy
```

### 4. Configure snmpd

```bash
sudo cp /opt/hubitat-printer-proxy/printer-proxy-snmp.conf /etc/snmp/snmpd.conf.d/
sudo systemctl restart snmpd
```

Edit `printer-proxy-snmp.conf` and update the `rocommunity` line to match your local subnet (the file contains `192.168.11.0/24` as an example).

`snmpd` only listens on loopback by default. Edit `/etc/snmp/snmpd.conf` and add your host's LAN IP to the `agentaddress` line so clients can reach it:

```
agentaddress 127.0.0.1,[::1],192.168.x.x
```

### 5. Point client at the proxy

For macOS, in **System Settings → Printers & Scanners**, add the printer using the proxy host's IP address and **HP Jetdirect – Socket** protocol on port 9100. Select your printer's PPD/driver as normal.

This requires the Dell driver to be installed on every client. See below for an alternative that renders on the proxy host instead.

## Optional: render on the proxy host instead of the client

By default, whatever's connecting to port 9100 is responsible for rendering PostScript/PDF into the printer's native language (HBPL) before it ever reaches the proxy — normally that's a Dell driver installed on the client. `setup-cups-driver.sh` moves that rendering step onto the proxy host itself, using the clean-room [biosed/dell-1320c-cups-driver](https://github.com/biosed/dell-1320c-cups-driver) filter chain (precompiled aarch64 binary), so clients just need a generic PostScript driver.

```
print client  ──IPP──►  CUPS (proxy host)  ──renders PS → HBPL──►  socket://127.0.0.1:9100
                                                                          │
                                                                    printer-proxy.py
                                                                  (power on, forward)
                                                                          │
                                                                          ▼
                                                                       Printer
```

`printer-proxy.py` doesn't change — it still just receives already-rendered bytes on 9100, powers the plug, and forwards. CUPS is simply a new client of the proxy, running locally.

```bash
sudo ./setup-cups-driver.sh
```

This installs `cups`, `ghostscript`, and `avahi-daemon`, downloads the driver tarball, installs the filters to `/opt/Dell1320/filter` and the PPD to `/usr/share/ppd/Dell/Dell-1320c.ppd`, and creates a shared CUPS queue (`Dell1320c` by default) with device URI `socket://127.0.0.1:9100` — i.e. back at the proxy's own listener.

Override `DRIVER_VERSION`, `QUEUE_NAME`, or `PROXY_PORT` as environment variables if needed.

Point clients at `ipp://<proxy-host-ip>/printers/Dell1320c` using a generic PostScript driver instead of the Dell driver — or, since the queue is shared and `avahi-daemon` is running, it should also show up automatically as an AirPrint printer to iOS/macOS clients on the same LAN.

## SNMP data served

The responder caches and serves the following MIB subtrees from the printer:

| OID | Description |
|-----|-------------|
| `1.3.6.1.2.1.43.5.1.1` | Printer general info |
| `1.3.6.1.2.1.43.7.1.1` | Input trays |
| `1.3.6.1.2.1.43.11.1.1` | Supply levels (ink/toner) |
| `1.3.6.1.2.1.43.12.1.1` | Media types |

## Hubitat setup

Enable the **Maker API** app on your Hubitat hub and add the smart plug device to it. The proxy uses the `on` command — power-off should be handled by a separate automation (e.g. a Rule that watches the plug's power reporting and turns off after wattage drops below idle for N seconds).

## Logs

```bash
journalctl -u printer-proxy -f
```
