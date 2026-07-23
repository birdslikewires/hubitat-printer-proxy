# hubitat-printer-proxy

Lightweight TCP proxy that sits between your client and a printer on a smart plug controlled via the Hubitat Maker API. The printer is powered on automatically when a print job arrives, and we keep the client happy about printer status by providing SNMP responses when the printer is powered off.

Rendering PostScript/PDF into the printer's native HBPL language can happen fully on the client, fully on the proxy host (driverless/AirPrint), or split between the two (real PPD/options on the client, rendering on the proxy host) — see [Point client at the proxy](#5-point-client-at-the-proxy) for the tradeoffs. All three use the clean-room [biosed/dell-1320c-cups-driver](https://github.com/biosed/dell-1320c-cups-driver) filter chain.

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
| `setup-macos-driver.sh` | macOS, fully local: installs the driver locally and points a CUPS queue at the proxy host |
| `setup-macos-thin-driver.sh` | macOS, split: installs just the PPD locally (options only) and renders remotely via the Pi's CUPS queue |
| `setup-cups-driver.sh` | Installs CUPS + the driver on the proxy host itself — required for `setup-macos-thin-driver.sh`, also usable standalone for driverless/AirPrint clients |

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

Whatever's connecting to port 9100 is responsible for rendering PostScript/PDF into the printer's native language (HBPL) before it ever reaches the proxy. `printer-proxy.py` never touches this — it just powers the plug and forwards whatever bytes it receives.

#### macOS clients: render locally

```
print client (Mac)  ──renders PS → HBPL locally──►  socket://<proxy-host>:9100
                                                             │
                                                       printer-proxy.py
                                                     (power on, forward)
                                                             │
                                                             ▼
                                                          Printer
```

`setup-macos-driver.sh` installs the macOS arm64 build of the clean-room [biosed/dell-1320c-cups-driver](https://github.com/biosed/dell-1320c-cups-driver) filter chain locally and creates a CUPS queue whose device URI points straight at the proxy host:

```bash
PROXY_HOST=192.168.x.x ./setup-macos-driver.sh
```

This gives you the real vendor PPD locally in **System Settings → Printers & Scanners**, so tray selection, FXColorMode (color/mono), and page geometry all work correctly — and CUPS's own SNMP supply-level polling queries the proxy host directly, which `snmp-responder.py` answers, so ink/toner levels show up as designed. Requires [Homebrew](https://brew.sh) (for Ghostscript).

To remove it later: `./setup-macos-driver.sh uninstall`.

#### macOS clients: real options locally, render on the proxy host (recommended)

```
print client (Mac)  ──IPP (plain PostScript)──►  ipp://<proxy-host>:631/printers/<remote queue>
                                                           │
                                                 CUPS on the Pi runs the
                                                 real FXM_* filter chain
                                                           │
                                                           ▼
                                                 socket://127.0.0.1:9100
                                                           │
                                                     printer-proxy.py
                                                   (power on, forward)
```

CUPS PPDs separate "what options the print dialog shows" from "what filters actually run" — you can install one without the other. `setup-macos-thin-driver.sh` installs a **local copy of the same PPD with the `*cupsFilter`/`*FXMainFilter`/`*FXFilterDir`/`*FXFilterChain` lines stripped out**, so macOS shows the real paper size / `FXColorMode` (color vs. black-only) / tray options, but never tries to run the FXM_* filters itself — no Ghostscript, no filter binaries, no Apple Silicon codesigning needed locally. The queue's device URI points at the Pi's *existing* CUPS queue over IPP (from `setup-cups-driver.sh`, which must already be set up), and that queue does the real rendering:

```bash
sudo ./setup-cups-driver.sh          # on the Pi, if not already done
PROXY_HOST=192.168.x.x ./setup-macos-thin-driver.sh   # on the Mac
```

This avoids the driverless/AirPrint attribute-translation gaps (below) while keeping the actual filter chain off the Mac entirely. **Don't run this and `setup-macos-driver.sh` for the same queue name** — one renders locally and one remotely, and running both would double-render the job (corrupting output).

To remove it later: `./setup-macos-thin-driver.sh uninstall`.

#### Other clients: render on the proxy host

For non-Mac clients, or if you'd rather not install anything locally, `setup-cups-driver.sh` puts CUPS + the same filter chain (Linux aarch64 build) on the proxy host itself, so clients just print via a generic PostScript/IPP driver instead:

```
print client  ──IPP──►  CUPS (proxy host)  ──renders PS → HBPL──►  socket://127.0.0.1:9100
                                                                          │
                                                                    printer-proxy.py
                                                                  (power on, forward)
                                                                          │
                                                                          ▼
                                                                       Printer
```

```bash
sudo ./setup-cups-driver.sh
```

This installs `cups`, `ghostscript`, and `avahi-daemon`, downloads the driver tarball, installs the filters to `/opt/Dell1320/filter` and the PPD to `/usr/share/ppd/Dell/Dell-1320c.ppd`, and creates a shared CUPS queue (`Dell1320c` by default) with device URI `socket://127.0.0.1:9100` — i.e. back at the proxy's own listener. It also opens CUPS to the LAN (`cupsctl --share-printers --remote-any`, plus switching `Listen localhost:631` to `Port 631` in `cupsd.conf`) since Debian/Raspberry Pi OS's default CUPS install only listens on loopback, and opens `631/tcp`/`5353/udp` in `ufw` if active.

Override `DRIVER_VERSION`, `QUEUE_NAME`, or `PROXY_PORT` as environment variables if needed. To remove everything it set up: `sudo ./setup-cups-driver.sh uninstall`.

**Caveat:** driverless/AirPrint clients only see standard IPP attributes, and CUPS's translation of this vendor-custom PPD's options (custom `FXColorMode`, tray keywords, non-standard media) into IPP isn't always reliable — in practice this can mean missing color/mono choice, missing supply levels, or misscaled/mispositioned output. If you hit that, prefer the local macOS driver above for Mac clients.

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
