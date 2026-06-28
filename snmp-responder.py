#!/usr/bin/env python3
"""
snmp-responder.py

snmpd pass_persist script. Serves cached printer SNMP data (Printer MIB,
.1.3.6.1.2.1.43) when the printer is off. Called and managed by snmpd.

pass_persist protocol (one OID per command):
  - snmpd sends "PING\n" → respond "PONG\n"
  - snmpd sends "get\n<oid>\n" → respond "<oid>\n<type>\n<value>\n"
  - snmpd sends "getnext\n<oid>\n" → respond with next OID in tree
  - On unknown OID → respond "NONE\n"
"""

import sys
import json
from pathlib import Path

# Must match SNMP_CACHE in printer-proxy.py
SNMP_CACHE	= Path("/opt/hubitat-printer-proxy/snmp-cache.json")


def oid_to_tuple(oid: str) -> tuple:
	return tuple(int(x) for x in oid.strip().lstrip(".").split("."))


def load_cache() -> tuple[dict, list]:
	try:
		raw = json.loads(SNMP_CACHE.read_text())
		cache = {}
		for k, v in raw.items():
			try:
				oid_to_tuple(k)
				cache[k] = v
			except (ValueError, AttributeError):
				pass
		return cache, sorted(cache.keys(), key=oid_to_tuple)
	except Exception:
		return {}, []


def parse_value(raw: str) -> tuple[str, str]:
	if ": " not in raw:
		return ("string", raw)
	type_part, val_part = raw.split(": ", 1)
	snmp_type = type_part.strip().lower()
	value = val_part.strip().strip('"')
	type_map = {"oid": "objid", "hex-string": "string"}
	return (type_map.get(snmp_type, snmp_type), value)


def write_triplet(oid: str, raw: str) -> None:
	snmp_type, value = parse_value(raw)
	sys.stdout.write(f"{oid}\n{snmp_type}\n{value}\n")
	sys.stdout.flush()


def none() -> None:
	sys.stdout.write("NONE\n")
	sys.stdout.flush()


def main() -> None:
	cache, sorted_oids = load_cache()

	while True:
		line = sys.stdin.readline()
		if not line:
			break
		cmd = line.strip()

		if cmd == "PING":
			cache, sorted_oids = load_cache()
			sys.stdout.write("PONG\n")
			sys.stdout.flush()
			continue

		if cmd in ("get", "getnext"):
			oid = sys.stdin.readline().strip().lstrip(".")
			if not oid:
				none()
				continue

			if cmd == "get":
				if oid in cache:
					write_triplet(oid, cache[oid])
				else:
					none()

			elif cmd == "getnext":
				try:
					req = oid_to_tuple(oid)
				except ValueError:
					none()
					continue
				next_oid = next((o for o in sorted_oids if oid_to_tuple(o) > req), None)
				if next_oid:
					write_triplet(next_oid, cache[next_oid])
				else:
					none()


if __name__ == "__main__":
	main()
