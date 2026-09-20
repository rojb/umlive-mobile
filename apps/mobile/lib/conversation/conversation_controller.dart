import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../l10n/app_localizations_es.dart';
import '../presentation/connection_controller.dart';
import '../presentation/discovered_scope.dart';
import 'deterministic_resolver.dart';
import 'operation_executor.dart';
import 'operation_resolver.dart';
import 'turn.dart';

/// Owns the conversation's turn list (`T11`).
///
/// Replaces the bare `List<String> _utterances` that `assistant_screen.dart`
/// used to hold directly: `CaptureSection`'s `onUtterance` callback feeds this
/// controller through [submitUtterance], the screen renders [turns] instead
/// of keeping its own state, and resolving an utterance is delegated to an
/// [OperationResolver] — the seam [DeterministicOperationResolver] fills in,
/// never this class.
///
/// Built in `AppServices.bootstrap()` like every other shared object, and
/// bound to the app's one [ConnectionController] instead of opening a second
/// source of truth for the registry, the address or the token.
class ConversationController extends ChangeNotifier {
  ConversationController(
    ConnectionController connection, {
    OperationResolver? resolver,
  }) : _connection = connection,
       // The shipped resolver is the deterministic one: `T12`'s read path is
       // in it and `T13` extends the same class with the write path. It is
       // defaulted here rather than required, the same way
       // `ConnectionController` defaults `BackendProbe` when the caller does
       // not hand it one.
       _resolver = resolver ?? const DeterministicOperationResolver(),
       _executor = connection.buildExecutor() {
    _connection.addListener(_onConnectionChanged);
    _syncGreeting();
  }

  static const String _greetingId = 'greeting';

  final ConnectionController _connection;
  final OperationResolver _resolver;
  final OperationExecutor _executor;

  /// The app pins its locale to Spanish in `main.dart` rather than exposing it
  /// as a setting, so constructing the concrete localizations class directly
  /// is what lets turn text be generated here, outside the widget tree — the
  /// same way `scopeGreeting` already takes `AppLocalizations` as a plain
  /// parameter instead of reaching for a `BuildContext`.
  final AppLocalizationsEs _l10n = AppLocalizationsEs();

  final List<ConversationTurn> _turns = <ConversationTurn>[];
  int _nextId = 0;

  /// The conversation, oldest first. [turns].first is always the greeting.
  List<ConversationTurn> get turns => List.unmodifiable(_turns);

  /// Adds [text] as a user turn and starts resolving it.
  ///
  /// Fire-and-forget by design, the same contract the old `onUtterance`
  /// callback had: `CaptureSection` calls this synchronously from a tap or a
  /// text submission and never awaits a network round trip itself.
  void submitUtterance(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final userTurn = UserTurn(
      id: _newId(),
      timestamp: DateTime.now(),
      text: trimmed,
    );
    final pendingId = _newId();
    final pendingTurn = AssistantTurn(
      id: pendingId,
      timestamp: DateTime.now(),
      text: _l10n.conversationPending,
      status: TurnStatus.pending,
    );
    _turns
      ..add(userTurn)
      ..add(pendingTurn);
    logEvent('conversation', {'action': 'submit', 'length': trimmed.length});
    notifyListeners();

    unawaited(_resolve(trimmed, pendingId));
  }

  Future<void> _resolve(String utterance, String pendingId) async {
    final registry = _connection.apiRegistry;
    final ResolverOutcome outcome;
    if (registry == null) {
      // Capture is only offered while `hasWorkableRegistry` holds, but the
      // registry is read again here rather than trusted from that earlier
      // check — the two moments are not the same await, and this class
      // never assumes state it can re-read for free.
      outcome = ResolverOutcome(
        replyText: _l10n.conversationNoRegistry,
        status: TurnStatus.failed,
      );
    } else {
      outcome = await _resolver.resolve(
        utterance: utterance,
        registry: registry,
        executor: _executor,
        l10n: _l10n,
      );
    }

    final index = _turns.indexWhere((turn) => turn.id == pendingId);
    if (index == -1) return;
    final pending = _turns[index];
    if (pending is! AssistantTurn) return;
    _turns[index] = pending.copyWith(
      text: outcome.replyText,
      status: outcome.status,
      evidence: outcome.evidence,
    );
    logEvent('conversation', {
      'action': 'resolved',
      'status': outcome.status.name,
      'operation': outcome.evidence?.operationKey,
    });
    notifyListeners();
  }

  void _onConnectionChanged() => _syncGreeting();

  /// Synthesizes the greeting the same way the old widget-level special case
  /// did — `l10n.assistantGreeting` with no registry, `scopeGreeting`
  /// otherwise — but as the first turn of [turns] rather than a widget drawn
  /// outside the list. Re-run on every connection change, so a registry that
  /// only loads after the first frame still ends up in the greeting.
  void _syncGreeting() {
    final registry = _connection.apiRegistry;
    final text = registry == null
        ? _l10n.assistantGreeting
        : scopeGreeting(_l10n, registry);

    if (_turns.isEmpty) {
      _turns.add(
        AssistantTurn(
          id: _greetingId,
          timestamp: DateTime.now(),
          text: text,
          status: TurnStatus.resolved,
        ),
      );
      notifyListeners();
      return;
    }

    final first = _turns.first;
    if (first is! AssistantTurn || first.id != _greetingId) {
      // The greeting is always inserted first, above; reaching here would
      // mean something else claimed that slot, which never happens.
      return;
    }
    if (first.text == text) return;
    _turns[0] = first.copyWith(text: text);
    notifyListeners();
  }

  String _newId() => (_nextId++).toString();

  @override
  void dispose() {
    _connection.removeListener(_onConnectionChanged);
    super.dispose();
  }
}
