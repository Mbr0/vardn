import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/database.dart';
import '../../services/providers.dart';
import '../../services/sync/peer_discovery.dart';
import '../../services/sync/peer_endpoint.dart';

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(deviceIdentityProvider);
    final engineAsync = ref.watch(syncEngineProvider);
    final discovered = ref.watch(discoveredPeersProvider).value ?? const [];
    final paired = ref.watch(pairedPeersProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final engine = await ref.read(syncEngineProvider.future);
              await engine.syncAllOnce();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sync triggered')),
                );
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader('This device'),
          identityAsync.when(
            loading: () => const _LoadingCard(),
            error: (e, _) => _ErrorCard('$e'),
            data: (identity) => _MyDeviceCard(
              identity: identity,
              port: engineAsync.value?.server.port,
            ),
          ),
          const SizedBox(height: 24),
          _SectionHeader('Paired (${paired.length})'),
          if (paired.isEmpty)
            const _EmptyCard('No paired devices yet. Tap "Pair a device" below.')
          else
            ...paired.map(
              (p) => _PairedPeerTile(
                peer: p,
                isOnline: discovered.any((d) => d.deviceId == p.id),
                onUnpair: () async {
                  final engine = await ref.read(syncEngineProvider.future);
                  await engine.unpair(p.id);
                },
                onEditRemote: () => _editRemoteAddress(context, ref, p),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Pair a device'),
            onPressed: () => _showPairFlow(context, ref),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.content_paste),
            label: const Text('Pair from pasted invite'),
            onPressed: () => _showManualPairFlow(context, ref),
          ),
          const SizedBox(height: 24),
          _SectionHeader('Discovered on LAN (${discovered.length})'),
          if (discovered.isEmpty)
            const _EmptyCard('No other Vardn devices on this network.')
          else
            ...discovered.map((d) => _DiscoveredTile(
                  peer: d,
                  alreadyPaired: paired.any((p) => p.id == d.deviceId),
                  onPair: () async {
                    final engine = await ref.read(syncEngineProvider.future);
                    await engine.savePeer(
                      id: d.deviceId,
                      publicKey: d.publicKey,
                      displayName: d.displayName,
                      endpoint: d.endpoint,
                    );
                  },
                )),
        ],
      ),
    );
  }

  Future<void> _showPairFlow(BuildContext context, WidgetRef ref) async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _PairScannerScreen()),
    );
    if (scanned == null) return;
    if (!context.mounted) return;
    await _pairFromInvite(context, ref, scanned);
  }

  /// Pair without a camera: paste the invite JSON (from "Copy invite JSON" on
  /// the other device, or printed by the headless vardn_node on startup).
  Future<void> _showManualPairFlow(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pair from invite'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '{"v":1,"id":...}',
            helperText: 'Paste the invite JSON from the other device',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;
    if (!context.mounted) return;
    await _pairFromInvite(context, ref, raw.trim());
  }

  Future<void> _pairFromInvite(
      BuildContext context, WidgetRef ref, String raw) async {
    final invite = _PairInvite.tryParse(raw);
    if (invite == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid pairing code')),
        );
      }
      return;
    }
    final engine = await ref.read(syncEngineProvider.future);
    await engine.savePeer(
      id: invite.deviceId,
      publicKey: invite.publicKey,
      displayName: invite.displayName,
      endpoint: invite.endpoint,
    );
    await engine.syncAllOnce();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Paired with ${invite.displayName}')),
      );
    }
  }

  /// Set/clear a peer's remote (Tailscale) address, used to reach it when
  /// it isn't visible on the local network.
  Future<void> _editRemoteAddress(
      BuildContext context, WidgetRef ref, Peer peer) async {
    final controller = TextEditingController(text: peer.staticEndpoint ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remote address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'my-server.tailnet.ts.net:8484',
            helperText:
                'host:port reachable when away from home (e.g. Tailscale '
                'IP or MagicDNS name). Leave empty to clear.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final engine = await ref.read(syncEngineProvider.future);
    if (result.isEmpty) {
      await engine.setStaticEndpoint(peer.id, null);
      return;
    }
    final endpoint = PeerEndpoint.tryParse(result);
    if (endpoint == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid address — use host:port')),
        );
      }
      return;
    }
    await engine.setStaticEndpoint(peer.id, endpoint);
    await engine.syncAllOnce();
  }
}

class _PairInvite {
  _PairInvite({
    required this.deviceId,
    required this.publicKey,
    required this.displayName,
    required this.endpoint,
  });

  final String deviceId;
  final String publicKey;
  final String displayName;
  final PeerEndpoint endpoint;

  static _PairInvite? tryParse(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      if (json['v'] != 1) return null;
      return _PairInvite(
        deviceId: json['id'] as String,
        publicKey: json['pk'] as String,
        displayName: json['name'] as String,
        endpoint: PeerEndpoint(
          host: json['host'] as String,
          port: json['port'] as int,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static String encode({
    required String deviceId,
    required String publicKey,
    required String displayName,
    required String host,
    required int port,
  }) =>
      jsonEncode({
        'v': 1,
        'id': deviceId,
        'pk': publicKey,
        'name': displayName,
        'host': host,
        'port': port,
      });
}

class _MyDeviceCard extends ConsumerWidget {
  const _MyDeviceCard({required this.identity, required this.port});
  final dynamic identity; // DeviceIdentity (avoid extra import)
  final int? port;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(identity.displayName,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            SelectableText(
              identity.shortFingerprint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (port == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              )
            else ...[
              FutureBuilder<String>(
                future: _firstLanIp(),
                builder: (ctx, snap) {
                  final host = snap.data ?? 'localhost';
                  final payload = _PairInvite.encode(
                    deviceId: identity.id,
                    publicKey: identity.publicKeyBase64,
                    displayName: identity.displayName,
                    host: host,
                    port: port!,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: QrImageView(
                          data: payload,
                          size: 220,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('LAN: $host:$port',
                          style: Theme.of(ctx).textTheme.bodySmall),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy invite JSON'),
                            onPressed: () => Clipboard.setData(
                                ClipboardData(text: payload)),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<String> _firstLanIp() async {
  // Pick any non-loopback IPv4 interface.
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
    includeLoopback: false,
  );
  for (final i in interfaces) {
    for (final addr in i.addresses) {
      if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
        return addr.address;
      }
    }
  }
  return 'localhost';
}

class _PairedPeerTile extends StatelessWidget {
  const _PairedPeerTile({
    required this.peer,
    required this.isOnline,
    required this.onUnpair,
    required this.onEditRemote,
  });

  final Peer peer;
  final bool isOnline;
  final VoidCallback onUnpair;
  final VoidCallback onEditRemote;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          isOnline ? Icons.cloud_done : Icons.cloud_off,
          color: isOnline ? Colors.green : Theme.of(context).colorScheme.outline,
        ),
        title: Text(peer.displayName.isEmpty ? peer.id.substring(0, 8) : peer.displayName),
        subtitle: Text(
          [
            if (peer.lastEndpoint != null) peer.lastEndpoint!,
            if (peer.staticEndpoint != null) 'remote: ${peer.staticEndpoint}',
            if (peer.lastSeenAt != null)
              'seen ${DateFormat.yMd().add_Hm().format(peer.lastSeenAt!.toLocal())}',
          ].join(' · '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'remote') onEditRemote();
            if (value == 'unpair') onUnpair();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'remote',
              child: ListTile(
                leading: Icon(Icons.vpn_lock),
                title: Text('Remote address…'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'unpair',
              child: ListTile(
                leading: Icon(Icons.link_off),
                title: Text('Unpair'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveredTile extends StatelessWidget {
  const _DiscoveredTile({
    required this.peer,
    required this.alreadyPaired,
    required this.onPair,
  });

  final DiscoveredPeer peer;
  final bool alreadyPaired;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.devices_other),
        title: Text(peer.displayName),
        subtitle: Text('${peer.endpoint} · ${peer.deviceId.substring(0, 8)}',
            style: const TextStyle(fontSize: 12)),
        trailing: alreadyPaired
            ? const Chip(label: Text('paired'))
            : FilledButton(onPressed: onPair, child: const Text('Pair')),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      );
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message),
        ),
      );
}

class _PairScannerScreen extends StatefulWidget {
  const _PairScannerScreen();
  @override
  State<_PairScannerScreen> createState() => _PairScannerScreenState();
}

class _PairScannerScreenState extends State<_PairScannerScreen> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_handled) return;
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw == null) continue;
            _handled = true;
            Navigator.of(context).pop(raw);
            return;
          }
        },
      ),
    );
  }
}
