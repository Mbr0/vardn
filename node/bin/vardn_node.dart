import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';

import 'package:vardn_node/event_store.dart';
import 'package:vardn_node/identity.dart';
import 'package:vardn_node/server.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('data-dir',
        help: 'Where identity + events are stored.',
        defaultsTo: p.join(_home(), '.vardn-node'))
    ..addOption('port', help: 'Port to listen on.', defaultsTo: '8484')
    ..addOption('bind',
        help: 'Address to bind (use your Tailscale IP to avoid exposing the '
            'node on other interfaces).',
        defaultsTo: '0.0.0.0')
    ..addOption('name', help: 'Display name shown on paired devices.')
    ..addOption('advertise-host',
        help: 'Host to put in the pairing invite — your Tailscale MagicDNS '
            'name or Tailscale IP. Defaults to the bind address.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }
  if (args['help'] as bool) {
    stdout.writeln('vardn_node — headless always-on Vardn sync peer\n');
    stdout.writeln(parser.usage);
    return;
  }

  final dataDir = Directory(args['data-dir'] as String);
  final port = int.tryParse(args['port'] as String) ?? 8484;
  final bind = args['bind'] as String;

  final identity =
      await NodeIdentity.load(dataDir, displayName: args['name'] as String?);
  final store = RelayEventStore(Directory(p.join(dataDir.path, 'events')));
  final server = NodeServer(identity: identity, store: store);
  await server.start(address: bind, port: port);

  final advertiseHost = (args['advertise-host'] as String?) ??
      (bind == '0.0.0.0' ? await _firstNonLoopbackIp() : bind);
  final invite = jsonEncode({
    'v': 1,
    'id': identity.id,
    'pk': identity.publicKeyBase64,
    'name': identity.displayName,
    'host': advertiseHost,
    'port': port,
  });

  stdout
    ..writeln('vardn_node "${identity.displayName}"')
    ..writeln('  fingerprint : ${identity.shortFingerprint}')
    ..writeln('  listening   : $bind:$port')
    ..writeln('  data dir    : ${dataDir.path}')
    ..writeln('')
    ..writeln('Pair from the app: Devices → "Pair a device" and scan the QR')
    ..writeln('below, or "Pair from pasted invite" with this JSON:')
    ..writeln('')
    ..writeln(invite)
    ..writeln('');
  _printQr(invite);
  stdout.writeln('\nRunning. Ctrl-C to stop.');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down…');
    await server.stop();
    exit(0);
  });
}

String _home() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    '.';

Future<String> _firstNonLoopbackIp() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  for (final i in interfaces) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a.address;
    }
  }
  return 'localhost';
}

/// Renders the invite as a scannable QR in the terminal. Terminals are usually
/// dark, so "light" QR modules are drawn as white blocks and "dark" modules as
/// background — with a quiet-zone border so scanners lock on.
void _printQr(String data) {
  final qr = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  );
  final image = QrImage(qr);
  const light = '██';
  const dark = '  ';
  final width = image.moduleCount + 4;
  final border = light * width;
  stdout.writeln(border);
  stdout.writeln(border);
  for (var y = 0; y < image.moduleCount; y++) {
    final row = StringBuffer(light * 2);
    for (var x = 0; x < image.moduleCount; x++) {
      row.write(image.isDark(y, x) ? dark : light);
    }
    row.write(light * 2);
    stdout.writeln(row);
  }
  stdout.writeln(border);
  stdout.writeln(border);
}
