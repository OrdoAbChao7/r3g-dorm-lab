# Link diagnosis notes

These two documents record the wired-link false positives that delayed the real
diagnosis. They are kept because the method is reusable:

- [NETWORK_LINK_FINAL_DIAGNOSIS.md](NETWORK_LINK_FINAL_DIAGNOSIS.md): link
  sampling, USB device removal, ARP/DHCP evidence.
- [NIC_CROSS_TEST.md](NIC_CROSS_TEST.md): built-in NIC cross-test.

The important conclusions:

- `Up` + `1 Gbps` is a PHY negotiation result, not proof of a working data path.
  RX bytes stayed at 0.
- A single `ping` reply can come from the wrong interface. Check
  `Find-NetRoute`, the source address and the interface index.
- Both NICs "failing" at once was more consistent with a router resetting every
  second than with two independent NIC failures.
- The USB NIC disappearing from the bus (`CM_PROB_PHANTOM`) is a separate USB-side
  event, not proof that the router's LAN port is dead.
- LED semantics matter: power, link and activity are different.

Identifiers in the copies here are placeholders; the raw captures stay private.
