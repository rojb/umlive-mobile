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
import 'speech_sink.dart';
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
/// It also owns the spoken side of a turn (`T15`). The conversation speaks
/// through a [SpeechSink] it knows nothing else about, so the synthesizer, the
/// pinned voice and the platform stay behind the voice layer. Speech is always
/// fire-and-forget: it never delays, fails or reorders a turn.
///
/// It also owns the one write in flight (`T13`, `T13b`): [pendingWrite] is the
/// write the conversation is assembling or confirming, and the next utterance
/// is an answer to it rather than a new command. The resolver stays stateless
/// and receives that write as a parameter.
class ConversationController extends ChangeNotifier {
  ConversationController(
    ConnectionController connection, {
    OperationResolver? resolver,
    SpeechSink? speech,
  }) : _connection = connection,
       // The shipped resolver is the deterministic one: `T12`'s read path and
       // the write paths of `T13` and `T13b` are all in it. It is defaulted
       // here rather than required, the same way `ConnectionController` defaults
       // `BackendProbe` when the caller does not hand it one.
       _resolver = resolver ?? const DeterministicOperationResolver(),
       _executor = connection.buildExecutor() {
    // The voice layer implements the port; `AppServices` hands over the app's
    // one `VoiceController`. Null means the conversation is silent — capture
    // and resolution still work, which is what makes the sink optional.
    // Assigned in the body rather than through `this._speech` so the named
    // parameter stays public while the field stays private to this library.
    _speech = speech;
    _connection.addListener(_onConnectionChanged);
    _syncGreeting();
  }

  static const String _greetingId = 'greeting';

  final ConnectionController _connection;
  final OperationResolver _resolver;
  final OperationExecutor _executor;

  /// The voice layer, or null when the conversation speaks nothing. Held as
  /// the [SpeechSink] port so nothing here can reach the engine, the voice or
  /// the platform.
  late final SpeechSink? _speech;

  /// The write in flight, if any (`T13`, `T13b`). Null when the conversation is
  /// not in the middle of a write — a create or a delete.
  ///
  /// It lives here and never inside the resolver, which is stateless: owning
  /// the write is what makes the next utterance an answer to a question instead
  /// of a new command.
  PendingWrite? _pending;

  /// The write the conversation is assembling or confirming, or null when
  /// there is none.
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

    // The cue before the wait (`FR-MD03`). A write that is awaiting
    // confirmation is about to be sent, so the operator must hear something
    // within 2 s of the utterance instead of silence that is indistinguishable
    // from failure. The two shapes that count are the same two the band
    // confirms with its own controls: a [PendingDelete], and a [PendingCreate]
    // whose phase is [WritePhase.confirming].
    //
    // A *collecting* draft deliberately speaks nothing extra: its question is
    // answered locally and instantly — no network call is made — and the next
    // question is spoken anyway, as the settled sentence of that same turn. A
    // cue here would be a promise of a wait that does not exist.
    if (_awaitsConfirmation) {
      _speak(_l10n.conversationResolvingCue, kind: 'cue');
    }

    unawaited(_resolve(trimmed, pendingId));
  }

  /// True when the write in flight is waiting for its affirmative, which means
  /// the next utterance is what sends it (`FR-MD03`).
  bool get _awaitsConfirmation {
    final pending = _pending;
    return pending is PendingDelete ||
        (pending is PendingCreate && pending.phase == WritePhase.confirming);
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
    // Every settled sentence is spoken, wherever it lands on screen. The UX
    // rule is that if text is in the assistant's voice, it was also spoken —
    // including the band's question or read-back, because [ResolverOutcome
    // .replyText] carries that sentence even while a write stays open. A
    // sentence that only appears in the list would be invisible to an operator
    // who is not looking at the handset, which is the whole point of `FR-MD03`.
    _speak(outcome.replyText, kind: 'turn');
    notifyListeners();
  }

  /// Speaks one sentence through the [SpeechSink], fire-and-forget (`T15`).
  ///
  /// Speech must never delay, fail or reorder a turn: the future is not
  /// awaited, a failed synthesis is a log line and nothing else, and an empty
  /// sentence is never spoken — silence is not a turn's answer, it is an
  /// accident. The log carries a **length**, never the sentence: the text is
  /// app copy, and the discipline this app keeps everywhere is that an
  /// operator's data does not reach the log.
  void _speak(String text, {required String kind}) {
    final sink = _speech;
    final trimmed = text.trim();
    if (sink == null || trimmed.isEmpty) return;
    logEvent('conversation', {
      'action': 'spoke',
      'kind': kind,
      'length': trimmed.length,
    });
    unawaited(
      sink.speak(trimmed).catchError((Object error) {
        logEvent('conversation', {'action': 'speak_failed'});
      }),
    );
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
