# Hosted network endpoints and filtering (H4)

Tessera.app networking (TarwinHosted.md HS-012, piece H4): each Tarwin
network endpoint is one BSD socket opened by tarwind. No vmnet, no raw
sockets, no name lookups (addresses are numeric).

- `HostedNetwork` is the only place hosted Tarwin opens host sockets:
  `connect` (TCP), `listen`/`accept` (TCP) and `datagram` (UDP). Sockets are
  non-blocking, close-on-exec and never raise SIGPIPE; each app has an open
  endpoint limit.
- `NetPolicy` filters every flow before the socket call: rules first (first
  match wins, by app, protocol, direction, prefix and ports), then the app's
  signed entitlements. `client` allows outbound flows and replies to them;
  `server` allows listening beyond loopback and peers from beyond it.
  Unknown apps, multicast and broadcast are denied unless a rule allows them.
- Filtered peers are closed at `accept`, and UDP datagrams from denied
  sources are dropped unless the app sent to that peer first. A denied flow
  never reaches `socket()`.

Run `swift test` here.
