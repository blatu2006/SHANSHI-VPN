#!/usr/bin/env python3
"""Generate the bundled China IPv4 CIDR snapshot from an APNIC delegated file."""

import argparse
import datetime
import ipaddress
from pathlib import Path


def networks_from_apnic(path: Path):
    networks = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = raw_line.split("|")
        if len(fields) < 7 or fields[1] != "CN" or fields[2] != "ipv4":
            continue
        start, count = fields[3], int(fields[4])
        networks.extend(ipaddress.summarize_address_range(
            ipaddress.IPv4Address(start),
            ipaddress.IPv4Address(int(ipaddress.IPv4Address(start)) + count - 1),
        ))
    return list(ipaddress.collapse_addresses(networks))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("delegated_file", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Sources/HillstonePacketTunnel/Resources/china_ipv4_cidrs.txt"),
    )
    args = parser.parse_args()
    routes = networks_from_apnic(args.delegated_file)
    if len(routes) < 1000:
        raise SystemExit(f"refusing suspicious APNIC result: only {len(routes)} routes")
    header = [
        "# NLVC VPN China mainland public IPv4 routes",
        "# Source: https://ftp.apnic.net/stats/apnic/delegated-apnic-latest",
        f"# Generated: {datetime.date.today().isoformat()}",
        f"# Route count: {len(routes)}",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(header + [str(route) for route in routes]) + "\n", encoding="utf-8")
    print(f"wrote {len(routes)} routes to {args.output}")


if __name__ == "__main__":
    main()
