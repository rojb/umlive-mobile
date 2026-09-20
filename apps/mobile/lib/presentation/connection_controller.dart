import 'package:flutter/foundation.dart';

import '../conversation/operation_executor.dart';
import '../core/log.dart';
import '../data/connection_profile.dart';
import '../data/profile_repository.dart';
import '../data/registry_repository.dart';
import '../net/backend_address.dart';
import '../net/backend_probe.dart';
import '../net/reachability.dart';
import '../openapi/registry.dart';
import '../openapi/registry_diff.dart';
import '../openapi/registry_parser.dart';

/// The single owner of connection state.
///
/// Screens read it and render it; they never probe, never normalize and never
/// touch storage themselves. Later tasks extend this class — the executor will
/// take the HTTP client and the token from here — instead of opening a second
/// source of truth.
///
/// Two rules govern the cache, and both are stated here because this is the
/// only place that decides them:
///
/// * **A document is persisted only when the parser accepted it as an OpenAPI
///   3.x description.** A body that failed to parse — HTML, a stray JSON
///   payload, a truncated read — never reaches the repository, so a bad fetch
///   can never overwrite the good registry the app falls back to offline.
/// * **When a probe does not deliver a description, the stored registry is the
///   authority** — no answer, a 404, or a 2xx body that is not a description.
///   The reachability state names why the live attempt failed; the registry the
///   app works with is the one the backend described last time (`FR-MA04`).
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

  /// The registry the app works with, from this session's document or from
  /// storage. Null means the app knows nothing about any backend.
  ApiRegistry? _apiRegistry;

  /// The stored row, read once per launch and refreshed after every write.
  CachedRegistry? _cachedRegistry;

  /// True while [_apiRegistry] is the stored registry rather than a document
  /// read in this session.
  bool _registryFromCache = false;

  RegistryDiff? _registryChange;
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

  /// The registry the app works with (`FR-MA03`, `FR-MA04`).
  ///
  /// Every name shown or spoken as discovered comes from here, and only from
  /// here: nothing is inferred from an entity name, a route or a guess.
  ApiRegistry? get apiRegistry => _apiRegistry;

  /// True when [apiRegistry] is the stored registry rather than a document read
  /// in this session. The copy owes the operator that distinction: remembered
  /// entities are not live ones.
  bool get registryFromCache => _registryFromCache;

  /// True when there is something to work with: a registry, fresh or cached,
  /// that carries at least one operation.
  ///
  /// A description that parsed but declares no operation is not workable, and
  /// Pass 6 of the UX spec asks for that to be said rather than shown as an
  /// empty conversation surface.
  bool get hasWorkableRegistry =>
      _apiRegistry != null && !_apiRegistry!.isEmpty;

  /// What the last successful re-discovery added and removed (`FR-MA07`), or
  /// null when there is nothing to report.
  ///
  /// Set only when the stored hash and the fetched one differ, and cleared at
  /// the start of every probe. A null here is what keeps the UX spec's
  /// *"registry changed since last connect"* element hidden.
  RegistryDiff? get registryChange => _registryChange;

  /// Why the last submitted address was refused, or null.
  AddressProblem? get addressProblem => _addressProblem;

  /// True while a probe is in flight: the UX spec's Connection *Loading* state.
  bool get isProbing => _probing;

  /// True when a bearer token is stored. The value is never exposed: only the
  /// transport layer below this class reads it.
  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// Builds an [OperationExecutor] bound to this controller's live address
  /// and token (`T11`).
  ///
  /// Chosen over adding a public token getter: the token stays a private
  /// field of this class, and the executor only ever sees the current address
  /// and token through the two closures below, re-read on every call rather
  /// than captured once — a reconnect to a different backend or a token
  /// change is therefore visible to a caller holding an executor built before
  /// it happened, with no second source of truth to fall out of sync.
  OperationExecutor buildExecutor() =>
      OperationExecutor(() => _address?.base, () => _token);

  /// True when the active address was accepted *and* is unencrypted, so the
  /// screen owes the user a visible warning (`PRD-MOBILE.md` §7).
  bool get showsCleartextWarning => _address?.isCleartext ?? false;

  /// True when the app can be used against the active backend: it answered with
  /// a description, or its earlier answer is cached.
  ///
  /// This reads the **effective** state, not the raw probe: a 2xx whose body
  /// turned out not to be a description is not a usable backend, even though
  /// the probe itself saw a successful status.
  bool get canProceed =>
      _reachability == ReachabilityState.connected ||
      _reachability == ReachabilityState.offlineWithCache;

  /// True when the backend answered but no description came out of it: a 404,
  /// or a body that is not an OpenAPI document (`FR-MA06`).
  ///
  /// This is the UX spec's Connection *Partial* state — the address is right,
  /// the backend is alive, and there is nothing to discover from it. The screen
  /// owes the cause by name and the two actions that can change the situation.
  bool get discoveryFailed =>
      _reachability == ReachabilityState.missingDescription ||
      _reachability == ReachabilityState.notAnApiDescription;

  /// Loads the stored profile **and the cached registry**. Local and fast: no
  /// network, so the first frame is never held behind a probe.
  ///
  /// Loading the cache here is what makes a cold start with no network work: by
  /// the time the first frame renders, the registry the app works with is
  /// already the one the backend described last time (`FR-MA04`).
  Future<void> loadStoredProfile() async {
    final stored = await _profiles.loadActive();
    if (stored == null) {
      _reachability = ReachabilityState.neverConnected;
      _address = null;
      _token = null;
      _profile = null;
      _cachedRegistry = null;
      _apiRegistry = null;
      _registryFromCache = false;
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
    await _loadCachedRegistry(stored.profile.id);
    _useStoredRegistry();
    notifyListeners();
  }

  /// Re-probes the stored backend without user action (UX Pass 4, "Defaults
  /// introduced": the last backend is reconnected automatically on launch).
  ///
  /// Also the **retry** action of the Connection *Partial* state: nothing about
  /// the address changes, so only the probe has to run again.
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

    final previousUrl = _address?.display;
    final stored = await _profiles.save(address: address, token: token);
    _profile = stored.profile;
    _address = stored.address;
    _token = stored.token;

    // A different backend is a different cache. The profile row is reused
    // across an address change, so the remembered registry has to be dropped
    // with the address it belonged to: keeping it would make the app claim
    // `offlineWithCache` about a backend it has never reached, and would show
    // another backend's entities as this one's.
    if (previousUrl != null && previousUrl != address.display) {
      await _registry.clear(stored.profile.id);
      _cachedRegistry = null;
      _apiRegistry = null;
      _registryFromCache = false;
      logEvent('registry', {
        'kind': 'cache',
        'result': 'cleared',
        'reason': 'address_changed',
      });
    }

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

  /// Runs one probe of the description path and turns its outcome into state.
  Future<void> _runProbe(BackendAddress address, String? token) async {
    final generation = ++_generation;
    _probing = true;
    _addressProblem = null;
    // A new attempt replaces the previous report: a stale change banner would
    // describe a document the operator has already moved past.
    _registryChange = null;
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

    if (result.state == ReachabilityState.connected) {
      // The backend answered with bytes. They are described below; the cache is
      // only reached for if they turn out not to be a description.
      await _handleDescription(
        body: result.bodyBytes,
        profileId: profileId,
        statusCode: result.statusCode,
      );
    } else {
      // The backend did not answer with a description: the stored registry is
      // the authority and nothing about it is touched (`FR-MA04`).
      _useStoredRegistry();
    }

    notifyListeners();

    if (result.state == ReachabilityState.connected && profileId != null) {
      await _profiles.touchConnectedAt(profileId);
    }
  }

  /// Turns the body of a 2xx description response into the registry to use.
  ///
  /// Two outcomes, two explicit treatments, and neither guesses (`FR-MA06`):
  ///
  /// * a parseable OpenAPI description — derive, persist, report a change;
  /// * anything else — say so by name, keep the stored registry usable, and
  ///   leave the stored row exactly as it was.
  Future<void> _handleDescription({
    required List<int>? body,
    required String? profileId,
    required int? statusCode,
  }) async {
    if (body == null) {
      _reachability = ReachabilityState.notAnApiDescription;
      _useStoredRegistry();
      logEvent('registry', {
        'kind': 'document',
        'result': 'no_body',
        'status': statusCode,
        'state': _reachability.name,
      });
      return;
    }

    final parsed = RegistryParser.parse(body);
    if (!parsed.isOpenApiDocument) {
      _reachability = ReachabilityState.notAnApiDescription;
      _useStoredRegistry();
      logEvent('registry', {
        'kind': 'document',
        'result': 'not_openapi',
        'status': statusCode,
        // The effective state, so a discovery failure is provable from
        // `adb logcat` without a screenshot. The probe's own line already says
        // the status it saw; this says what the app did about it.
        'state': _reachability.name,
        'bytes': body.length,
        'hash': parsed.registry.documentHash,
        'diagnostics': parsed.registry.diagnostics.length,
      });
      return;
    }

    _apiRegistry = parsed.registry;
    _registryFromCache = false;
    _logRegistry(parsed);
    if (profileId != null) {
      await _persist(profileId: profileId, parsed: parsed);
    }
  }

  /// Persists a discovery, or reports why it did not (`FR-MA07`).
  ///
  /// Reaching this method already means the document was accepted as a
  /// description, so the only question left is whether it *changed*: an
  /// identical document rewrites nothing — the row would be byte-identical —
  /// and shows nothing, because the UX spec keeps the change element hidden
  /// until it happens.
  Future<void> _persist({
    required String profileId,
    required RegistryParseResult parsed,
  }) async {
    final registry = parsed.registry;
    final storedHash = await _registry.storedHash(profileId);

    if (storedHash == registry.documentHash) {
      logEvent('registry', {
        'kind': 'persist',
        'result': 'skipped',
        'reason': 'unchanged',
        'hash': registry.documentHash,
      });
      return;
    }

    final fetchedAt = DateTime.now().millisecondsSinceEpoch;
    await _registry.save(
      profileId: profileId,
      parsed: parsed,
      fetchedAt: fetchedAt,
    );
    logEvent('registry', {
      'kind': 'persist',
      'result': 'written',
      'hash': registry.documentHash,
      'previousHash': storedHash,
      'operations': registry.operations.length,
      'entities': registry.entities.length,
      'fetchedAt': fetchedAt,
    });

    if (storedHash == null) {
      // The first description for this backend: there is nothing for it to have
      // changed against, so nothing is reported and the element stays hidden.
      await _loadCachedRegistry(profileId);
      return;
    }

    // The document changed. The diff is computed against the registry that was
    // stored, so it says what the backend can do now that it could not before.
    final previous = _cachedRegistry?.registry;
    if (previous == null) {
      // A stored hash with no readable stored registry: the change is real and
      // the report is not available. Say so instead of reporting an empty diff,
      // which would read as "nothing changed" when the opposite is true.
      logEvent('registry', {
        'kind': 'change',
        'added': 'unavailable',
        'removed': 'unavailable',
        'reason': 'stored_registry_unreadable',
      });
      await _loadCachedRegistry(profileId);
      return;
    }

    final diff = RegistryDiff.between(previous, registry);
    _registryChange = diff;
    // Counts first, then the keys: logcat truncates a very long line, and the
    // counts are what a glance needs to survive that truncation.
    logEvent('registry', {
      'kind': 'change',
      'addedCount': diff.added.length,
      'removedCount': diff.removed.length,
      'added': diff.added.isEmpty ? 'none' : diff.added.join(','),
      'removed': diff.removed.isEmpty ? 'none' : diff.removed.join(','),
    });

    // Re-read so the in-memory cached registry is the row that was just
    // written; the registry in use stays the one this session derived.
    await _loadCachedRegistry(profileId);
  }

  /// Reads the stored row into memory and logs what it holds.
  ///
  /// The cached row is read on every launch, before any probe: offline, it is
  /// the whole of what the app knows.
  Future<void> _loadCachedRegistry(String profileId) async {
    final cached = await _registry.load(profileId);
    _cachedRegistry = cached;
    if (cached == null) return;

    final registry = cached.registry;
    logEvent('registry', {
      'kind': 'cache',
      'result': 'loaded',
      'hash': registry.documentHash,
      'openapi': registry.openapiVersion,
      'operations': registry.operations.length,
      'entities': registry.entities.length,
      'fetchedAt': cached.fetchedAt,
    });
    // One line per entity, in the shape a live discovery logs them, so an
    // offline cold start can be proven to list the same names.
    for (final entity in registry.entities) {
      logEvent('registry', {
        'kind': 'entity',
        'source': 'cache',
        'name': entity.name,
        'route': entity.collectionRoute,
      });
    }
  }

  /// Points the registry in use at the stored one.
  ///
  /// Called whenever the live attempt produced no description — and on launch,
  /// before there has been one. With nothing stored, the app then knows nothing
  /// about any backend, which is the honest state: no entities, no routes, and
  /// no surface that pretends otherwise.
  void _useStoredRegistry() {
    final cached = _cachedRegistry;
    _apiRegistry = cached?.registry;
    _registryFromCache = cached != null;
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
