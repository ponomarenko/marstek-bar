# Security

MarstekBar only sends read requests to the battery over the local network and stores
the battery's IP address and charge history on the Mac. It makes no internet connections.

To report a vulnerability, use
[private vulnerability reporting](https://github.com/ponomarenko/marstek-bar/security/advisories/new)
instead of a public issue. Only the latest version on `main` is supported.

Note that the Marstek Local Open API itself has no authentication: any device on the
same network can read and control the battery. That is a property of the battery
firmware, not of this app.
