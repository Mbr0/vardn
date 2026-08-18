# Vardn

Local-first todo + notes app with peer-to-peer sync — over the LAN (mDNS + HTTP event
log) and, away from home, over [Tailscale](https://tailscale.com) via static
peer addresses and/or the headless [`node/`](node/README.md) relay.

A Canopy Studio product.

## Stack

- Flutter + Drift (SQLite)
- Todos (lists, tags, due dates) and block-based notes (text, checklists,
  links, images — reorderable)
- Images sync as content-addressed blobs (SHA-256) over `/blobs` routes,
  verified on receipt and replicated lazily between peers and the node
- LAN peer discovery via `_vardn._tcp`
- Event-log sync between paired devices
- Optional always-on relay peer (`node/`, pure Dart) for sync when devices
  aren't online at the same time

## Syncing away from home

1. Put your devices (and optionally a home server) on the same tailnet.
2. Either set a peer's **Remote address…** (Devices → ⋮ on a paired device)
   to its Tailscale `host:port`, or run `vardn_node` on the server and pair
   both phones with it — see [node/README.md](node/README.md).

## Development

```bash
flutter pub get
flutter run
```

## Release

```bash
./release.sh
```

Builds iOS IPA and Android AAB. See `release.sh` for output paths.

Android release builds are signed with the upload key configured in
`android/key.properties` (gitignored — see the comments in
`android/app/build.gradle.kts` for the expected keys and the `keytool`
command to generate a keystore). Without that file, release builds fall
back to debug signing so `flutter run --release` still works.

## Identifiers

| Platform | Value |
|---|---|
| Package | `vardn` |
| iOS / Android | `com.canopystudio.vardn` |
| Display name | Vardn |
