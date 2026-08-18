/// A network address for a peer — discovered via mDNS or configured by the
/// user (e.g. a Tailscale IP / MagicDNS name for syncing away from home).
class PeerEndpoint {
  PeerEndpoint({required this.host, required this.port});

  final String host;
  final int port;

  Uri uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  /// Parses `host:port`, including bracketed IPv6 like `[fd7a::1]:8484`.
  static PeerEndpoint? tryParse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    final sep = s.lastIndexOf(':');
    if (sep <= 0 || sep == s.length - 1) return null;
    var host = s.substring(0, sep);
    final port = int.tryParse(s.substring(sep + 1));
    if (port == null || port < 1 || port > 65535) return null;
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    } else if (host.contains(':')) {
      return null; // unbracketed IPv6 — ambiguous, reject
    }
    if (host.isEmpty) return null;
    return PeerEndpoint(host: host, port: port);
  }

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is PeerEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
