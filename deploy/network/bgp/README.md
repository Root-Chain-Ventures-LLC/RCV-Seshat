# Router examples for Seshat BGP anycast (HA mode 3)

One example per platform. Each one peers with every Seshat node, accepts **only** the service
host routes (a /32 and a /128) through a prefix-list, sends nothing back, and installs one path per
node (ECMP). The operator guide is [`docs/ha.md`](../../../docs/ha.md#mode-3-bgp-anycast).

| File | Platform |
|---|---|
| [`frr.conf`](frr.conf) | FRRouting  |
| [`cisco-iosxe.txt`](cisco-iosxe.txt) | Cisco IOS-XE |
| [`juniper-junos.txt`](juniper-junos.txt) | Juniper Junos |
| [`arista-eos.txt`](arista-eos.txt) | Arista EOS |
| [`mikrotik-routeros.rsc`](mikrotik-routeros.rsc) | MikroTik RouterOS 7 |
| [`vyos.txt`](vyos.txt) | VyOS 1.4 |

## Addresses used (documentation ranges, change them)

| What | IPv4 | IPv6 |
|---|---|---|
| Router (its address towards the nodes) | 192.0.2.1 | 2001:db8:ffff::1 |
| Seshat node 1 / 2 / 3 | 192.0.2.11 / .12 / .13 | 2001:db8:ffff::11 / ::12 / ::13 |
| Anycast service address (the one senders use) | 198.51.100.10/32 | 2001:db8:100::10/128 |
| Router AS / Seshat AS (private) | 65000 / 65010 | |
| Router IDs of the nodes | 192.0.2.11 / .12 / .13 | |

Matching Seshat configuration (Cluster > BGP anycast > Configure, or `PUT /api/cluster/bgp`): local
AS 65010, router IDs per node, one IPv4 neighbour 192.0.2.1 AS 65000 with prefix 198.51.100.10/32,
one IPv6 neighbour 2001:db8:ffff::1 AS 65000 with prefix 2001:db8:100::10/128, the same password on
both sides if you use one.

## Rules every example follows

- **Neighbour to each node**, not to the anycast address. Seshat connects out to the router and the router
  stays passive towards the nodes (it accepts, it does not initiate): with TTL security the library's
  listener does not answer with TTL 255, so a session the router starts may be discarded by the router itself.
  Leave `listen_port` off in Seshat.
- **Import only the service prefixes** (exact /32 and /128), reject everything else, and export
  nothing to the nodes. A misbehaving node can then never inject a route.
- **ECMP**: `maximum-paths` at least as large as the number of nodes. All nodes share one AS, so the
  paths tie on AS-path length and neighbouring AS; no multipath-relax is needed.
- **Hold time 9 s, keepalive 3 s** to match Seshat's defaults (the lower value wins in the
  negotiation). Seshat withdraws explicitly on every planned change, so the timers only matter for
  a host that dies without a TCP reset.
- **BFD is optional** and not provided by Seshat. Where the platform supports it the example shows
  the line, commented out; it needs a BFD responder on the node's host (for example FRR `bfdd`).
- **Hashing**: make the router hash on source (and destination) address so one sender stays on one
  node. The platform notes are in each file and in the ECMP section of the guide.
- **GTSM (TTL security, RFC 5082)**: Seshat turns it on by default for a directly connected eBGP
  neighbour added now (one stored by an earlier version keeps it off): it sends with TTL 255 and the kernel drops anything of that session that arrives with less,
  so only a router on the same link can reach the BGP port. The router must do the same or the session
  never comes up: `frr.conf` has `ttl-security hops 1`; the other platforms have an equivalent (Cisco and
  VyOS `ttl-security hops 1`, Arista `ttl maximum-hops 1`; check the name for your release). For a
  neighbour that cannot do GTSM, or is more than one hop away, set `ttl_security` to `false` (and
  `multihop_ttl` to the hop count) in the Seshat neighbour entry.
- **Passwords**: the TCP-MD5 key is optional. Use the same key as in the Seshat neighbour entry.
  `CHANGE-ME` is a placeholder, not a default.

## Status of these files

They were written from the vendors' documentation for current releases. Only the FRR file has been
exercised, in a container lab; the others have not been run against real devices. Command names change between releases: read
them as a template and check them in a lab first.
