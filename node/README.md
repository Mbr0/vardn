# vardn_node

A headless, always-on Vardn peer for your home server. It speaks the same
HTTP sync protocol as the app, but instead of applying events to a database it
simply **stores and forwards** them: phones push their mutation events to it
and pull everyone else's from it. That means two phones never need to be
online at the same time to stay in sync — and paired with
[Tailscale](https://tailscale.com), sync works away from home too.

It's pure Dart — no Flutter needed on the server.

## Run

```sh
cd node
dart pub get
dart run bin/vardn_node.dart \
  --name "home-server" \
  --bind <your-tailscale-ip> \
  --advertise-host <your-machine>.your-tailnet.ts.net
```

Options:

| Flag | Default | Meaning |
|---|---|---|
| `--data-dir` | `~/.vardn-node` | Identity + event storage |
| `--port` | `8484` | Listen port |
| `--bind` | `0.0.0.0` | Bind address — use your Tailscale IP so the node is only reachable inside your tailnet |
| `--name` | hostname | Display name shown in the app |
| `--advertise-host` | bind/LAN IP | Host written into the pairing invite (use your MagicDNS name) |

On startup it prints a pairing invite as both JSON and a terminal QR code.

## Pair your phones

On each phone: **Devices → Pair a device** and scan the terminal QR, or
**Pair from pasted invite** and paste the JSON (send it to yourself over any
private channel). Because the invite carries the node's Tailscale hostname,
the endpoint works from anywhere your tailnet reaches.

For direct phone↔phone sync away from home, open the ⋮ menu on a paired
device and set **Remote address…** to that device's Tailscale `host:port`.

## Security model

The node performs no authentication itself (same as the app's LAN sync,
"phase 2a"). Rely on the network layer: bind it to the Tailscale interface so
only devices in your tailnet can reach it, and don't expose the port on the
public internet.

## Keep it running (systemd)

```ini
# /etc/systemd/system/vardn-node.service
[Unit]
Description=Vardn sync node
After=network-online.target tailscaled.service

[Service]
ExecStart=/usr/bin/dart run /opt/vardn/node/bin/vardn_node.dart --name home-server --bind 100.x.y.z --advertise-host myserver.your-tailnet.ts.net
Restart=on-failure
User=vardn

[Install]
WantedBy=multi-user.target
```

Or compile once and run the binary: `dart compile exe bin/vardn_node.dart -o vardn_node`.

## Storage layout

```
~/.vardn-node/
  identity.json            # X25519 keypair + display name
  events/<deviceId>/<ts>-<type>-<eventId>.json
  blobs/<sha256-hex>       # note attachments (images), content-addressed
```

Same event format and watermark semantics as the app's own outbox, so the
node doubles as a plain-file backup of the full mutation history.
