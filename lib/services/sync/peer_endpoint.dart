/// A network address for a peer (typically discovered via mDNS).
class PeerEndpoint {
  PeerEndpoint({required this.host, required this.port});

  final String host;
  final int port;

  Uri uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  @override
  String toString() => '$host:$port';
}
