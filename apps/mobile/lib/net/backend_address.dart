import 'transport_policy.dart';

/// Why a typed address could not be turned into a usable backend address.
///
/// The screens translate each value into its own sentence; nothing here holds
/// user-facing copy.
enum AddressProblem {
  /// Nothing was typed.
  empty,

  /// Not `host` or `host:port`: it has a path, a query, credentials, or it does
  /// not parse as a URI authority at all.
  malformed,

  /// A scheme other than `http` or `https`.
  unsupportedScheme,

  /// The port is present but outside 1–65535.
  invalidPort,

  /// Cleartext HTTP towards a non-local address. Refused, never upgraded.
  cleartextRefused,
}

/// A backend address the app is willing to use.
///
/// [base] is the normalized form: `scheme://host[:port]`, no path, no trailing
/// slash, lowercase host. It is what is stored, displayed and probed.
class BackendAddress {
  const BackendAddress({required this.base, required this.transport});

  final Uri base;
  final TransportSecurity transport;

  /// The canonical text of the address.
  String get display => base.toString();

  /// True when the address is accepted *and* unencrypted, so the UI owes the
  /// user a visible warning.
  bool get isCleartext => transport == TransportSecurity.cleartextPrivate;

  @override
  String toString() => 'BackendAddress($display, ${transport.name})';
}

/// Result of normalizing typed text.
sealed class AddressOutcome {
  const AddressOutcome();
}

final class AddressAccepted extends AddressOutcome {
  const AddressAccepted(this.address);

  final BackendAddress address;
}

final class AddressRejected extends AddressOutcome {
  const AddressRejected(this.problem);

  final AddressProblem problem;
}

/// Normalization of the address field (`FR-MA01`).
///
/// Pure: no storage, no network, no copy. It accepts what a user can plausibly
/// paste out of a browser or a tunnel dashboard:
///
/// * `https://xxx.trycloudflare.com`
/// * `http://192.168.1.40:8080`
/// * `192.168.1.40:8080` (scheme inferred: private, so `http`)
/// * `mi-backend.example.com` (scheme inferred: not local, so `https`)
/// * any of the above with a trailing `/` or a trailing `/v3/api-docs`
abstract final class BackendAddressParser {
  static const String _descriptionPath = '/v3/api-docs';

  static final RegExp _schemePattern = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://');

  static AddressOutcome parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const AddressRejected(AddressProblem.empty);

    // A user copying out of a browser tab hands over the whole description URL.
    // Strip that and any trailing slashes before looking at the structure.
    text = _stripTrailingSlashes(text);
    if (text.toLowerCase().endsWith(_descriptionPath)) {
      text = _stripTrailingSlashes(
        text.substring(0, text.length - _descriptionPath.length),
      );
    }
    if (text.isEmpty) return const AddressRejected(AddressProblem.malformed);

    final String scheme;
    var authority = '';
    final schemeMatch = _schemePattern.firstMatch(text);
    if (schemeMatch != null) {
      scheme = schemeMatch.group(1)!.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        return const AddressRejected(AddressProblem.unsupportedScheme);
      }
      authority = text.substring(schemeMatch.end);
    } else {
      authority = text;
      // FR-MA01: default to https — a tunnel is the address that reaches this
      // app from anywhere — unless the host is loopback or private, where the
      // developer's own backend is plain http and typing the scheme is noise.
      scheme = TransportPolicy.allowsCleartext(_hostOf(authority))
          ? 'http'
          : 'https';
      authority = _bracketBareIpv6(authority);
    }

    // Only `host` or `host:port` survives: everything else is a different thing
    // than a base URL, and silently truncating it would hide the mistake.
    if (authority.isEmpty ||
        authority.contains('/') ||
        authority.contains('?') ||
        authority.contains('#')) {
      return const AddressRejected(AddressProblem.malformed);
    }

    if (_hasBadPort(authority)) {
      return const AddressRejected(AddressProblem.invalidPort);
    }

    final uri = Uri.tryParse('$scheme://$authority');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return const AddressRejected(AddressProblem.malformed);
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      return const AddressRejected(AddressProblem.malformed);
    }

    final transport = TransportPolicy.classify(uri);
    if (transport == TransportSecurity.cleartextRefused) {
      return const AddressRejected(AddressProblem.cleartextRefused);
    }

    return AddressAccepted(
      BackendAddress(
        // Rebuilt rather than reused so the stored form has no default port,
        // no trailing slash, no path and no fragment.
        base: Uri(
          scheme: scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
        ),
        transport: transport,
      ),
    );
  }

  static String _stripTrailingSlashes(String text) {
    var value = text;
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// The host part of an authority, without port and without brackets.
  static String _hostOf(String authority) {
    if (authority.startsWith('[')) {
      final end = authority.indexOf(']');
      return end == -1 ? '' : authority.substring(1, end);
    }
    final colon = authority.indexOf(':');
    if (colon == -1) return authority;
    // More than one colon and no brackets: a bare IPv6 literal, not host:port.
    if (authority.indexOf(':', colon + 1) != -1) return authority;
    return authority.substring(0, colon);
  }

  /// `::1` typed without brackets is a host, not a port; make it a legal URI.
  static String _bracketBareIpv6(String authority) {
    if (authority.startsWith('[')) return authority;
    final first = authority.indexOf(':');
    if (first == -1 || authority.indexOf(':', first + 1) == -1) return authority;
    return '[$authority]';
  }

  /// True when a port is present but is not a number in 1–65535.
  ///
  /// Checked before `Uri` sees the text so the user gets the port as the
  /// reason, instead of a generic "not an address".
  static bool _hasBadPort(String authority) {
    final String portText;
    if (authority.startsWith('[')) {
      final end = authority.indexOf(']');
      if (end == -1) return true;
      if (end == authority.length - 1) return false;
      if (authority[end + 1] != ':') return true;
      portText = authority.substring(end + 2);
    } else {
      final colon = authority.indexOf(':');
      if (colon == -1) return false;
      // More than one colon and no brackets: an IPv6 literal, not host:port.
      if (authority.indexOf(':', colon + 1) != -1) return false;
      portText = authority.substring(colon + 1);
    }
    final port = int.tryParse(portText);
    return port == null || port < 1 || port > 65535;
  }
}
