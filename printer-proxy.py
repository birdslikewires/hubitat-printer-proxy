#!/usr/bin/env python3
"""
printer-proxy.py

Listens on port 9100 (JetDirect). When a print job arrives, fires the
Hubitat API to power on the printer's smart plug, then transparently
forwards the TCP stream to the printer.

After each job completes, queries the printer's SNMP and caches the
supply/status data for serving via snmpd pass_persist (snmp-responder.py).

Power-off is handled separately by a Hubitat automation watching wattage.
"""

import os
import socket
import threading
import urllib.request
import subprocess
import json
import logging
import sys
import time
from pathlib import Path

LISTEN_HOST		= "0.0.0.0"
LISTEN_PORT		= 9100
PRINTER_PORT	= 9100
BUFFER_SIZE		= 4096

PRINTER_HOST	= os.environ["PRINTER_HOST"]
HUBITAT_HOST	= os.environ["HUBITAT_HOST"]
HUBITAT_APP		= os.environ["HUBITAT_APP"]
HUBITAT_TOKEN	= os.environ["HUBITAT_TOKEN"]
HUBITAT_DEVICE	= os.environ["HUBITAT_DEVICE"]

SNMP_COMMUNITY	= "public"
# Must match SNMP_CACHE in snmp-responder.py
SNMP_CACHE	= Path("/opt/hubitat-printer-proxy/snmp-cache.json")

logging.basicConfig(
	level=logging.INFO,
	format="%(asctime)s [%(levelname)s] %(message)s",
	handlers=[logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger(__name__)


def hubitat(action: str) -> None:
	url = (
		f"http://{HUBITAT_HOST}/apps/api/{HUBITAT_APP}"
		f"/devices/{HUBITAT_DEVICE}/{action}"
		f"?access_token={HUBITAT_TOKEN}"
	)
	try:
		with urllib.request.urlopen(url, timeout=5) as resp:
			log.info(f"Plug {action}: HTTP {resp.status}")
	except Exception as e:
		log.error(f"Plug {action} failed: {e}")


def snmp_cache() -> None:
	"""Query the printer's SNMP and cache results to disk."""
	log.info("Caching SNMP data from printer...")
	cache = {}
	try:
		result = subprocess.run(
			["snmpwalk", "-On", "-v1", "-c", SNMP_COMMUNITY, PRINTER_HOST, "1.3.6.1.2.1.43"],
			capture_output=True, text=True, timeout=30
		)
		for line in result.stdout.strip().splitlines():
			if " = " not in line:
				continue
			oid_part, value_part = line.split(" = ", 1)
			cache[oid_part.strip().lstrip(".")] = value_part.strip()
	except Exception as e:
		log.error(f"SNMP walk failed: {e}")

	if cache:
		try:
			tmp = SNMP_CACHE.with_suffix(".tmp")
			tmp.write_text(json.dumps(cache, indent=2))
			tmp.rename(SNMP_CACHE)
			log.info(f"SNMP cache written ({len(cache)} OIDs)")
		except Exception as e:
			log.error(f"Failed to write SNMP cache: {e}")
	else:
		log.warning("SNMP cache empty — printer may not have responded")


def forward(src: socket.socket, dst: socket.socket) -> None:
	"""Forward data from src to dst until the connection closes."""
	try:
		while True:
			data = src.recv(BUFFER_SIZE)
			if not data:
				break
			dst.sendall(data)
	except OSError:
		pass
	finally:
		try:
			dst.shutdown(socket.SHUT_WR)
		except OSError:
			pass


def connect_to_printer(host: str, port: int, retries: int = 15, delay: float = 2.0) -> socket.socket:
	"""Try to connect to the printer, retrying until it's ready."""
	for attempt in range(1, retries + 1):
		try:
			sock = socket.create_connection((host, port), timeout=5)
			log.info(f"Connected to printer on attempt {attempt}")
			return sock
		except OSError as e:
			log.warning(f"Printer not ready (attempt {attempt}/{retries}): {e}")
			if attempt < retries:
				time.sleep(delay)
	raise OSError(f"Printer did not become ready after {retries} attempts")


def handle(client: socket.socket, addr: tuple) -> None:
	log.info(f"Job received from {addr[0]}:{addr[1]}")

	hubitat("on")

	try:
		printer = connect_to_printer(PRINTER_HOST, PRINTER_PORT)
	except OSError as e:
		log.error(f"Could not connect to printer: {e}")
		client.close()
		return

	# Bidirectional forwarding — one thread each direction
	t = threading.Thread(target=forward, args=(printer, client), daemon=True)
	t.start()
	forward(client, printer)
	t.join()

	printer.close()
	client.close()
	log.info(f"Job from {addr[0]}:{addr[1]} complete")

	# Cache SNMP data in background — printer is on and warm
	threading.Thread(target=snmp_cache, daemon=True).start()


def main() -> None:
	server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
	server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	server.bind((LISTEN_HOST, LISTEN_PORT))
	server.listen(5)
	log.info(f"Listening on {LISTEN_HOST}:{LISTEN_PORT}")
	log.info(f"Proxying to {PRINTER_HOST}:{PRINTER_PORT}")

	while True:
		client, addr = server.accept()
		threading.Thread(target=handle, args=(client, addr), daemon=True).start()


if __name__ == "__main__":
	main()
