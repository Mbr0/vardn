# Vardn

Local-first task app with peer-to-peer sync over LAN (mDNS + HTTP event log).

A Canopy Studio product.

## Stack

- Flutter + Drift (SQLite)
- LAN peer discovery via `_vardn._tcp`
- Event-log sync between paired devices

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

## Identifiers

| Platform | Value |
|---|---|
| Package | `vardn` |
| iOS / Android | `com.canopystudio.vardn` |
| Display name | Vardn |
