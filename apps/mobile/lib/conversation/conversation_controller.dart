import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../data/outbox_repository.dart';
import '../l10n/app_localizations_es.dart';
import '../net/reachability.dart';
import '../presentation/connection_controller.dart';
import '../presentation/discovered_scope.dart';
import 'deterministic_resolver.dart';
import 'operation_executor.dart';
import 'operation_resolver.dart';
import 'outbox_drainer.dart';
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
///
/// It also triggers the automatic drain (`T16`). When reachability returns to
/// [ReachabilityState.connected] it starts one [OutboxDrainer] run and reports
/// every outcome as its own turn (`FR-MD04`, `FR-MD08`); sending is the
/// drainer's, so this class never sends anything itself.
///
/// It owns the queue's state as well (`T18`). The queue screen reads
/// [queueItems] and [queuedCount] from here, and every change goes through
/// [refreshQueue], [cancelQueued] and [retryQueued], so the screen never opens
/// the database — and the badge and the list behind it can never disagree,
/// because both are projections of the same read.
class ConversationController extends ChangeNotifier {
  ConversationController(
    ConnectionController connection, {
    required OutboxRepository outbox,
    OperationResolver? resolver,
    SpeechSink? speech,
  }) : _connection = connection,
       // The shipped resolver is the deterministic one: `T12`'s read path and
       // the write paths of `T13` and `T13b` are all in it. It is defaulted
       // here rather than required, the same way `ConnectionController` defaults
       // `BackendProbe` when the caller does not hand it one.
       _resolver = resolver ?? const DeterministicOperationResolver(),
       _executor = connection.buildExecutor() {
    // The queue the drain sends from. Assigned here for the same reason
    // `_speech` is: the drainer reads it, and the initializer list cannot
    // reference it through `this`.
    _outbox = outbox;
    // The drain is built from the connection's public surface and nothing else:
    // a live profile id, the outbox-free replay executor, the live registry,
    // and `FR-MD01`'s *the backend answered*.
    _drainer = OutboxDrainer(
      outbox: _outbox,
      profileIdOf: () => connection.profileId,
      executorOf: connection.buildReplayExecutor,
      registryOf: () => connection.apiRegistry,
      isReachable: () =>
          connection.reachability == ReachabilityState.connected,
    );
    // The voice layer implements the port; `AppServices` hands over the app's
    // one `VoiceController`. Null means the conversation is silent — capture
    // and resolution still work, which is what makes the sink optional.
    // Assigned in the body rather than through `this._speech` so the named
    // parameter stays public while the field stays private to this library.
    _speech = speech;
    _connection.addListener(_onConnectionChanged);
    _syncGreeting();
    // The badge and the list start from what the queue actually holds, so a
    // cold start that finds rows left by a force-kill shows them before any
    // drain runs (`T18`, `FR-MD06`). Fire-and-forget: opening the database must
    // not hold the frame that builds the first screen.
    unawaited(refreshQueue());
  }

  static const String _greetingId = 'greeting';

  final ConnectionController _connection;

  /// The durable queue (`T16`, `T18`). The drain sends from it, and the queue
  /// screen reads it through [queueItems] — never from the database itself.
  late final OutboxRepository _outbox;
  final OperationResolver _resolver;
  final OperationExecutor _executor;

  /// The drain of the durable queue (`T16`). Built here because this class is
  /// what knows when reachability returns and what to say about the outcome.
  late final OutboxDrainer _drainer;

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

  /// The queue as the last read saw it, in issue order (`T18`).
  ///
  /// A projection of the `outbox` table and never a second source of truth:
  /// every change to the queue is followed by [refreshQueue], and the
  /// repository stays the only thing that persists.
  List<OutboxItem> _queue = const <OutboxItem>[];

  /// The outstanding queue in issue order, as the last read saw it (`T18`).
  ///
  /// The queue screen builds from this inside a `ListenableBuilder`; it is a
  /// plain getter over the projection [refreshQueue] keeps, because a view
  /// that awaited the database could not be built.
  List<OutboxItem> get queueItems => List<OutboxItem>.unmodifiable(_queue);

  /// How many items the app-bar badge counts (`T18`).
  ///
  /// The length of exactly [queueItems], so the number in the app bar and the
  /// list behind it can never disagree — including while a drain is sending
  /// the head, because that item is still a promise the app has not kept.
  int get queuedCount => _queue.length;

  /// Re-reads the queue for the live profile and notifies (`T18`).
  ///
  /// Called at bootstrap, after every drain, after every cancel or retry, and
  /// when the queue screen appears. It re-projects the repository, plus the one
  /// repair described below: a state left behind by a process that is gone is
  /// not a fact about the item, so it is cleared here rather than shown.
  Future<void> refreshQueue() async {
    final profileId = _connection.profileId;
    if (profileId == null || profileId.isEmpty) {
      _queue = const <OutboxItem>[];
      notifyListeners();
      return;
    }
    // A row a process that died mid-send left `inFlight` is not in flight in
    // this one, and nothing else would ever clear it: the drain's own view
    // excludes it, so the screen would show it as *sending* for good while it
    // is never sent and cannot be discarded — a promise neither kept nor taken
    // back. It is recovered **before** the list is read, so the projection
    // below is the recovered queue and not the stale one.
    //
    // This is the right place because `refreshQueue` is the boundary the queue
    // is re-read through: it runs at bootstrap, when no send of this process
    // can be in flight yet, and again after every drain, cancel and retry — so
    // the recovery always runs on the queue's own terms, right where the app
    // decides what the queue holds, and never from a screen that happened to be
    // opened.
    await _outbox.recoverInFlight(profileId);
    final items = await _outbox.outstanding(profileId);
    _queue = items;
    notifyListeners();
  }

  /// Cancels one queued item: the operator withdrawing a promise the app made
  /// (`FR-MD07`), never a decision this class takes on its own.
  ///
  /// The row is removed first, so the queue is the truth immediately and the
  /// list and the badge follow it. A cancel is the operator's decision about a
  /// promise, so it is logged. When the item removed was the head of the
  /// queue, the command behind it is no longer blocked, so a drain is asked for
  /// (`FR-MD04`): the next item may now be sendable.
  Future<void> cancelQueued(int id) async {
    final wasHead = _queue.isNotEmpty && _queue.first.id == id;
    await _outbox.remove(id);
    logEvent('conversation', <String, Object?>{
      'action': 'cancel_queued',
      'id': id,
      'head': wasHead,
    });
    await refreshQueue();
    if (wasHead) unawaited(requestDrain());
  }

  /// Returns a failed item to the queue, so the next drain retries it in its
  /// original place (`FR-MD08`, `FR-MD04`).
  ///
  /// **Only a failed item can be retried.** `FR-MD08` retains a failed replay
  /// *for retry or cancellation*, and the UX spec puts retry on the failed
  /// item only: a pending item has not failed yet, so there is nothing to
  /// retry and offering the control would suggest the app had already tried. An
  /// in-flight item is being sent right now, so it is not retried either.
  Future<void> retryQueued(int id) async {
    final index = _queue.indexWhere((item) => item.id == id);
    if (index == -1) return;
    if (_queue[index].status != OutboxStatus.failed) return;
    await _outbox.markPending(id);
    logEvent('conversation', <String, Object?>{
      'action': 'retry_queued',
      'id': id,
    });
    await refreshQueue();
    unawaited(requestDrain());
  }

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

  void _onConnectionChanged() {
    _syncGreeting();
    unawaited(requestDrain());
  }

  /// Asks for a drain when the backend is reachable (`FR-MD04`).
  ///
  /// The one entry point to ask — the reachability listener, a cancel and a
  /// retry all come through it, so the queue screen never starts a run itself.
  /// Fire-and-forget: catching up on the queue must never hold the frame that
  /// asked. The guard is read synchronously here, before the run's first
  /// `await`, so a drain that answers an operation cannot retrigger itself
  /// through the reachability notification its own result produces.
  Future<void> requestDrain() async {
    if (_connection.reachability != ReachabilityState.connected) {
      // `FR-MD04` drains on reachability returning, and this is the branch that
      // says it has not returned yet. The run is never started, so the
      // drainer's own `step=skip` lines never appear and a queue that is simply
      // waiting looks exactly like a queue whose drain is broken — which is how
      // the `TFY-LX3` defect read. One line makes the absence provable from
      // `adb logcat`. Behaviour is unchanged: nothing is sent.
      logEvent('outbox', <String, Object?>{
        'action': 'drain',
        'step': 'skip',
        'reason': 'offline',
      });
      return;
    }
    if (_drainer.isDraining) return;
    unawaited(
      _drain().catchError((Object error) {
        // The drainer never throws for an ordinary outcome; anything that
        // reaches here is not one, and a fire-and-forget future must still not
        // become an unhandled error.
        logEvent('outbox', <String, Object?>{
          'action': 'drain',
          'step': 'error',
          'reason': error.runtimeType.toString(),
        });
      }),
    );
  }

  Future<void> _drain() async {
    final report = await _drainer.drain();
    _reportDrain(report);
    // The run is over, so the list and the badge re-read what it left: a sent
    // item is gone, a failed one is retained with its reason, and the two
    // counts follow without anything else asking (`T18`).
    await refreshQueue();
  }

  /// Reports every drained item as its own turn (`FR-MD08`).
  ///
  /// One assistant turn per outcome, resolved for a send and failed for a
  /// refusal, so a replay that fails is surfaced rather than silently dropped.
  /// The queued turn that promised the write keeps its own text — history is
  /// history — and this new turn says what finally happened to it. Linking the
  /// outcome back onto that original turn would be a presentation improvement
  /// for a later task, and nothing here fakes that link.
  void _reportDrain(DrainReport report) {
    if (report.outcomes.isEmpty) return;
    for (final outcome in report.outcomes) {
      final text = _drainText(outcome);
      _turns.add(
        AssistantTurn(
          id: _newId(),
          timestamp: DateTime.now(),
          text: text,
          status: outcome is DrainSent
              ? TurnStatus.resolved
              : TurnStatus.failed,
        ),
      );
      // The queued promise was made aloud, so keeping it is said aloud too:
      // the sentence that promised the write would go to the queue was spoken
      // as it settled, and this is the sentence that closes it. Same
      // fire-and-forget path a settled outcome uses — an outcome turn is an
      // assistant turn like any other (§19) — issued per outcome in the order
      // the report carries them, and the speech layer already serializes, so
      // two outcomes in one run are heard in sequence.
      _speak(text, kind: 'turn');
    }
    notifyListeners();
  }

  /// The copy for one drained item.
  ///
  /// Chosen by the item's kind, by whether the registry gave it a domain word,
  /// and by whether the backend answered with a status — never built here. An
  /// item that belongs to no entity of the current registry gets the honest
  /// generic sentence instead of a name nothing can supply.
  String _drainText(DrainOutcome outcome) {
    final entity = outcome.entityName;
    final create = outcome.kind == OutboxKind.create;
    switch (outcome) {
      case DrainSent():
        if (entity == null) return _l10n.outboxItemSentGeneric;
        return create
            ? _l10n.outboxCreateSent(entity)
            : _l10n.outboxDeleteSent(entity);
      case DrainFailed(:final statusCode):
        if (entity == null) return _l10n.outboxItemOrphanFailed;
        if (create) {
          return statusCode == null
              ? _l10n.outboxCreateFailedNoAnswer(entity)
              : _l10n.outboxCreateFailedStatus(entity, statusCode);
        }
        return statusCode == null
            ? _l10n.outboxDeleteFailedNoAnswer(entity)
            : _l10n.outboxDeleteFailedStatus(entity, statusCode);
    }
  }

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
