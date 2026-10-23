# MikroTik RouterOS 7: Seshat anycast, three nodes, IPv4 and IPv6, one AS for all nodes.
# Documentation-range addresses and private ASNs; replace them.
#
# RouterOS hashes ECMP flows on source and destination address by default for routed traffic. After
# loading, check that every node appears as a next hop of the service address:
#   /ip route print where dst-address=198.51.100.10/32
# If only one is active, check that the routes are equal (same distance, same attributes) and read
# the RouterOS "ECMP" documentation for your version: ECMP behaviour differs between 7.x releases.

/routing filter rule
add chain=seshat-in rule="if (dst == 198.51.100.10/32) { accept }"
add chain=seshat-in rule="if (dst == 2001:db8:100::10/128) { accept }"
add chain=seshat-in rule="reject"
add chain=seshat-out rule="reject"

/routing bgp template
add name=seshat as=65000 router-id=192.0.2.1 address-families=ip,ipv6 \
    input.filter=seshat-in output.filter-chain=seshat-out multihop=no

/routing bgp connection
add name=seshat-1 template=seshat remote.address=192.0.2.11 remote.as=65010 local.role=ebgp \
    hold-time=9s keepalive-time=3s
add name=seshat-2 template=seshat remote.address=192.0.2.12 remote.as=65010 local.role=ebgp \
    hold-time=9s keepalive-time=3s
add name=seshat-3 template=seshat remote.address=192.0.2.13 remote.as=65010 local.role=ebgp \
    hold-time=9s keepalive-time=3s
add name=seshat-1-v6 template=seshat remote.address=2001:db8:ffff::11 remote.as=65010 local.role=ebgp \
    hold-time=9s keepalive-time=3s
add name=seshat-2-v6 template=seshat remote.address=2001:db8:ffff::12 remote.as=65010 local.role=ebgp \
    hold-time=9s keepalive-time=3s
add name=seshat-3-v6 template=seshat remote.address=2001:db8:ffff::13 remote.as=65010 local.role=ebgp \
    hold-time=9s keepalive-time=3s
# TCP-MD5 password (same key as in the Seshat neighbour entry), per connection:
#   set seshat-1 tcp-md5-key=CHANGE-ME
# Optional BFD (needs a responder on the node host):
#   set seshat-1 use-bfd=yes
