import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../data/connection_profile.dart';
import '../data/profile_repository.dart';
import '../data/registry_repository.dart';
import '../net/backend_address.dart';
import '../net/backend_probe.dart';
import '../net/reachability.dart';
import '../openapi/registry.dart';
import '../openapi/registry_parser.dart';

/// The single owner of connection state.
///
/// Screens read it and render it; they never probe, never normalize and never
/// touch storage themselves. Later tasks extend this class — the executor will
/// take the HTTP client and the token from here — instead of opening a second
/// source of truth.
class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this._profiles,
    this._registry, {
    BackendProbe? probe,
  }) : _probe = probe ?? BackendProbe();

  final ProfileRepository _profiles;
  final RegistryRepository _registry;
  final BackendProbe _probe;

  ConnectionProfile? _profile;
  BackendAddress? _address;
  String? _token;
  ReachabilityState _reachability = ReachabilityState.neverConnected;
  ProbeResult? _lastProbe;
  ApiRegistry? _apiRegistry;
  AddressProblem? _addressProblem;
  bool _probing = false;

  /// Bumped on every probe and on every cancel. A result carrying a stale
  /// generation is discarded, so a cancelled probe can never overwrite the
  /// state of the one that replaced it.
  int _generation = 0;

  /// True when an address is stored and usable as a target.
  bool get hasStoredProfile => _address != null;

  /// The normalized address currently in use, or null when nothing is stored.
  BackendAddress? get address => _address;

  /// The state `FR-MA05` puts on screen.
  ReachabilityState get reachability => _reachability;

  /// The evidence behind [reachability], for the technical detail of `FR-ME06`.
  ProbeResult? get lastProbe => _lastProbe;

  /// The registry derived from the backend's own description (`FR-MA03`).
  ///
  /// Null until a probe has answered with a document this session. T3 keeps it
  /// in memory only: persisting it is T4's job (`FR-MA04`).
  ApiRegistry? get apiRegistry => _apiRegistry;

  /// Why the last submitted address was refused, or null.
  AddressProblem? get addressProblem => _addressProblem;

  /// True while a probe is in flight: the UX spec's Connection *Loading* state.
  bool get isProbing => _probing;

  /// True when a bearer token is stored. The value is never exposed: only the
  /// transport layer below this class reads it.
  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// True when the active address was accepted *and* is unencrypted, so the
  /// screen owes the user a visible warning (`PRD-MOBILE.md` §7).
  bool get showsCleartextWarning => _address?.isCleartext ?? false;

  /// True when the app can be used against the active backend: it answered, or
  /// its earlier answer is cached.
  bool get canProceed => _lastProbe?.isUsable ?? false;

  /// Loads the stored profile. Local and fast: no network, so the first frame
  /// is never held behind a probe.
  Future<void> loadStoredProfile() async {
    final stored = await _profiles.loadActive();
    if (stored == null) {
      _reachability = ReachabilityState.neverConnected;
      _address = null;
      _token = null;
      _profile = null;
      logEvent('profile', {'action': 'restore', 'result': 'none'});
      notifyListeners();
      return;
    }
    _profile = stored.profile;
    _address = stored.address;
    _token = stored.token;
    logEvent('profile', {
      'action': 'restore',
      'result': 'loaded',
      'id': stored.profile.id,
      'url': stored.address.display,
      'transport': stored.address.transport.name,
    });
    notifyListeners();
  }

  /// Re-probes the stored backend without user action (UX Pass 4, "Defaults
  /// introduced": the last backend is reconnected automatically on launch).
  Future<void> probeStored() async {
    final address = _address;
    if (address == null) return;
    await _runProbe(address, _token);
  }

  /// Normalizes, stores and probes a typed address.
  ///
  /// Returns true when the result leaves the app usable against that backend.
  Future<bool> connect({required String rawAddress, String? token}) async {
    final outcome = BackendAddressParser.parse(rawAddress);
    if (outcome is AddressRejected) {
      _addressProblem = outcome.problem;
      _probing = false;
      logEvent('address', {
        'result': 'rejected',
        'problem': outcome.problem.name,
      });
      notifyListeners();
      return false;
    }

    final address = (outcome as AddressAccepted).address;
    _addressProblem = null;
    logEvent('address', {
      'result': 'accepted',
      'url': address.display,
      'transport': address.transport.name,
    });

    final stored = await _profiles.save(address: address, token: token);
    _profile = stored.profile;
    _address = stored.address;
    _token = stored.token;
    notifyListeners();

    await _runProbe(stored.address, stored.token);
    return canProceed;
  }

  /// Cancels the probe in flight. Nothing else is touched: the last confirmed
  /// state stays on screen.
  void cancel() {
    if (!_probing) return;
    _generation++;
    _probe.cancel();
    _probing = false;
    logEvent('probe', {'action': 'cancelled'});
    notifyListeners();
  }

  /// Clears the refusal message once the user edits the address again.
  void clearAddressProblem() {
    if (_addressProblem == null) return;
    _addressProblem = null;
    notifyListeners();
  }

  /// True when the backend's description was fetched successfully, which is the
  /// point at which T3 takes over.
  Future<void> _runProbe(BackendAddress address, String? token) async {
    final generation = ++_generation;
    _probing = true;
    _addressProblem = null;
    notifyListeners();

    final profileId = _profile?.id;
    var hasCache = false;
    if (profileId != null) {
      hasCache = await _registry.hasRegistry(profileId);
    }

    final result = await _probe.fetchDescription(
      base: address.base,
      token: token,
      hasCachedRegistry: hasCache,
    );

    if (generation != _generation) return;

    _probing = false;
    _lastProbe = result;
    _reachability = result.state;
    logEvent('probe', {
      'url': result.url,
      'status': result.statusCode,
      'state': result.state.name,
      'ms': result.elapsedMs,
    });

    // T3: a backend that answered described itself. Parse the bytes the probe
    // already read into the registry the resolvers read; any other state means
    // no registry this session (T4 adds the cached one).
    if (result.state == ReachabilityState.connected) {
      final body = result.bodyBytes;
      if (body == null) {
        _apiRegistry = null;
      } else {
        final parsed = RegistryParser.parse(body);
        _apiRegistry = parsed.registry;
        _logRegistry(parsed);
      }
    } else {
      _apiRegistry = null;
    }

    notifyListeners();

    if (result.state == ReachabilityState.connected && profileId != null) {
      await _profiles.touchConnectedAt(profileId);
    }
  }

  /// KR2 evidence: one line per derived operation, then the summary.
  ///
  /// `method` and `path` are what the emitted controllers can be compared
  /// against; the summary counts are what proves 100 % coverage instead of
  /// spot-checking. A diagnostic is logged too, so a document the parser could
  /// not fully read is visible from `adb logcat` and never silent.
  void _logRegistry(RegistryParseResult parsed) {
    final registry = parsed.registry;
    // One line pinning the document itself: the version the parser accepted and
    // the SHA-256 T4 compares on the next connect (`FR-MA07`).
    logEvent('registry', {
      'kind': 'document',
      'openapi': registry.openapiVersion,
      'hash': registry.documentHash,
    });
    for (final operation in registry.operations) {
      logEvent('registry', {
        'kind': 'operation',
        'method': operation.method,
        'path': operation.path,
        'operationId': operation.operationId,
      });
    }
    // One line per entity: the recovered un-folded name, the route it groups
    // under, and the required writable fields in schema order. This is the
    // evidence for `FR-MC07` (vocabulary) and `FR-MC02` (slot filling).
    for (final entity in registry.entities) {
      logEvent('registry', {
        'kind': 'entity',
        'name': entity.name,
        'route': entity.collectionRoute,
        'required': entity.requiredWritableFields
            .map((field) => field.name)
            .join(','),
      });
    }
    for (final diagnostic in registry.diagnostics) {
      logEvent('registry', {
        'kind': 'diagnostic',
        'code': diagnostic.code,
        'path': diagnostic.path,
        'method': diagnostic.method,
      });
    }
    logEvent('registry', {
      'kind': 'summary',
      'operations': registry.operations.length,
      'entities': registry.entities.length,
      'paths': registry.pathCount,
      'diagnostics': registry.diagnostics.length,
      'ms': parsed.elapsedMs,
    });
  }

  @override
  void dispose() {
    _probe.cancel();
    super.dispose();
  }
}
