/// Transport security of a backend address.
///
/// `PRD-MOBILE.md` §7, "Security — transport": cleartext HTTP is permitted only
/// for explicit private-range addresses and warns; tunnels must be HTTPS.
///
/// This is a pure decision about a host, with no I/O, so discovery, the
/// executor and the connect screen all answer the same question the same way
/// instead of each re-deriving "is this local?".
enum TransportSecurity {
  /// Encrypted transport. Always accepted.
  secure,

  /// Cleartext HTTP to a loopback or private-range address. Accepted, and
  /// surfaced with a visible warning because the connection is unencrypted.
  cleartextPrivate,

  /// Cleartext HTTP to anything else. Refused with the reason stated. It is
  /// never silently upgraded to HTTPS and never silently downgraded either.
  cleartextRefused,
}

abstract final class TransportPolicy {
  /// Loopback hostnames. `localhost` and `127.0.0.0/8` are the same interface.
  static const Set<String> _loopbackNames = <String>{'localhost'};

  /// True for IPv6 `::1`, the IPv4 loopback block `127.0.0.0/8`, and
  /// `localhost`.
  static bool isLoopback(String host) {
    final normalized = _normalize(host);
    if (normalized.isEmpty) return false;
    if (_loopbackNames.contains(normalized)) return true;
    if (normalized == '::1') return true;
    return normalized.startsWith('127.');
  }

  /// True for `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`.
  ///
  /// Hostnames are not private by virtue of their spelling: a name has to be
  /// resolved to be classified, and resolution is not this function's job.
  static bool isPrivateRange(String host) {
    final normalized = _normalize(host);
    final octets = _ipv4Octets(normalized);
    if (octets == null) return false;
    if (octets[0] == 10) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    return false;
  }

  /// FR-MA01: cleartext is accepted only towards a loopback or private address.
  static bool allowsCleartext(String host) =>
      isLoopback(host) || isPrivateRange(host);

  /// Classifies [uri] by scheme and host.
  ///
  /// Only `http` and `https` reach this function: the address normalizer in
  /// `backend_address.dart` rejects every other scheme before it gets here, and
  /// this method refuses anything it does not recognize rather than guessing.
  static TransportSecurity classify(Uri uri) {
    switch (uri.scheme) {
      case 'https':
        return TransportSecurity.secure;
      case 'http':
        return allowsCleartext(uri.host)
            ? TransportSecurity.cleartextPrivate
            : TransportSecurity.cleartextRefused;
      default:
        return TransportSecurity.cleartextRefused;
    }
  }

  static String _normalize(String host) {
    var value = host.trim().toLowerCase();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }
    // A fully qualified name with a trailing dot is the same host.
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Parses a dotted quad into four octets, or null if it is not one.
  static List<int>? _ipv4Octets(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      octets.add(value);
    }
    return octets;
  }
}
