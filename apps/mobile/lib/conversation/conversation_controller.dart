import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../l10n/app_localizations_es.dart';
import '../presentation/connection_controller.dart';
import '../presentation/discovered_scope.dart';
import 'deterministic_resolver.dart';
import 'operation_executor.dart';
import 'operation_resolver.dart';
import 'pending_write.dart';
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
///
/// It also owns the one write in flight (`T13`): [pendingWrite] is the draft the
/// conversation is assembling, and the next utterance is an answer to it rather
/// than a new command. The resolver stays stateless and receives that draft as a
/// parameter.
class ConversationController extends ChangeNotifier {
  ConversationController(
    ConnectionController connection, {
    OperationResolver? resolver,
  }) : _connection = connection,
       // The shipped resolver is the deterministic one: `T12`'s read path and
       // `T13`'s create path are both in it. It is defaulted here rather than
       // required, the same way `ConnectionController` defaults `BackendProbe`
       // when the caller does not hand it one.
       _resolver = resolver ?? const DeterministicOperationResolver(),
       _executor = connection.buildExecutor() {
    _connection.addListener(_onConnectionChanged);
    _syncGreeting();
  }

  static const String _greetingId = 'greeting';

  final ConnectionController _connection;
  final OperationResolver _resolver;
  final OperationExecutor _executor;

  /// The write in flight, if any (`T13`). Null when the conversation is not in
  /// the middle of a create.
  ///
  /// It lives here and never inside the resolver, which is stateless: owning
  /// the draft is what makes the next utterance an answer to a question instead
  /// of a new command.
  PendingWrite? _pending;

  /// The write the conversation is assembling, or null when there is none.
  PendingWrite? get pendingWrite => _pending;

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

  /// Confirms the write the band is showing.
  ///
  /// It submits the control's own label as an ordinary utterance through
  /// [submitUtterance], so the affirmative rule and the confirmation logic exist
  /// in exactly one place — the resolver — and a touch and a spoken *sí* cannot
  /// drift apart.
  void confirmPendingWrite() =>
      submitUtterance(_l10n.conversationWriteConfirmAction);

  /// Cancels the write the band is showing, the same way: through the ordinary
  /// resolution path, so a touch and a spoken *no* share one implementation.
  void cancelPendingWrite() =>
      submitUtterance(_l10n.conversationWriteCancelAction);

  Future<void> _resolve(String utterance, String pendingId) async {
    // The draft in flight before this resolve: the resolver receives it, so it
    // is read here, and it is what tells an outcome that moved the conversation
    // from one that only answered again.
    final previous = _pending;
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
        pending: previous,
      );
    }

    final index = _turns.indexWhere((turn) => turn.id == pendingId);
    if (index == -1) return;
    final pendingTurn = _turns[index];
    if (pendingTurn is! AssistantTurn) return;

    final advanced =
        previous == null ||
        outcome.pending == null ||
        previous != outcome.pending;
    _pending = outcome.pending;
    if (outcome.pending != null && advanced) {
      // The band owns the question; a sentence that does not move the
      // conversation is a turn. A question or a read-back advances the
      // conversation, so it lives in the Response focus band and not in the
      // list: the assistant turn added for this utterance is removed and the
      // user's turn stays, while the pending "Resolviendo la indicación…" turn
      // is what the operator sees while the answer is being worked out, before
      // it settles into a question the band shows.
      //
      // A rejected answer or an unrecognised confirmation advances nothing, so
      // it stays a turn where the operator can read it, and the band keeps
      // asking its own question — two different sentences, never the same one
      // twice. The measured defect was exactly that: an invalid field value
      // (`conversationWriteFieldInvalid`) was rejected silently, because the
      // turn carrying the sentence was removed while the band only re-asked.
      _turns.removeAt(index);
    } else {
      _turns[index] = pendingTurn.copyWith(
        text: outcome.replyText,
        status: outcome.status,
        evidence: outcome.evidence,
      );
    }
    logEvent('conversation', {
      'action': 'resolved',
      'status': outcome.status.name,
      'operation': outcome.evidence?.operationKey,
      'pending': _pending != null,
      'advanced': advanced,
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
