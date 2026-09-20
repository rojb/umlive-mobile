import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/drain_service.dart';
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
///
/// It also owns the drain window (`T19`). Because it owns the queue, it is the
/// only object that knows whether the app still owes the operator an answer
/// while the app is not on screen, so it is the one that opens and closes the
/// foreground service that keeps the process scheduled for the drain, and the
/// one that keeps its notification's count equal to the queue behind it.
class ConversationController extends ChangeNotifier with WidgetsBindingObserver {
  ConversationController(
    ConnectionController connection, {
    required OutboxRepository outbox,
    OperationResolver? resolver,
    SpeechSink? speech,
    DrainService? drainService,
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
    // `FR-MD01`'s *the backend answered*, and the read cache a successful
    // replay has to invalidate (`FR-ME04`). That cache is the connection's own
    // instance, not a second one: a replay and the conversation have to drop
    // the same remembered reads.
    _drainer = OutboxDrainer(
      outbox: _outbox,
      profileIdOf: () => connection.profileId,
      executorOf: connection.buildReplayExecutor,
      registryOf: () => connection.apiRegistry,
      isReachable: () =>
          connection.reachability == ReachabilityState.connected,
      readCache: connection.readCache,
    );
    // The voice layer implements the port; `AppServices` hands over the app's
    // one `VoiceController`. Null means the conversation is silent — capture
    // and resolution still work, which is what makes the sink optional.
    // Assigned in the body rather than through `this._speech` so the named
    // parameter stays public while the field stays private to this library.
    _speech = speech;
    // The drain window's service (`T19`). Built here rather than in
    // `AppServices`, which builds the *shared* objects: nothing else in the app
    // reads or drives this one, and the object that owns the queue is the only
    // thing that can decide when a window is owed. `AppServices` still composes
    // the conversation, so the dependency is injectable and a caller can hand
    // over another implementation.
    _drainService = drainService ?? DrainService();
    _connection.addListener(_onConnectionChanged);
    // The drain window follows the app's lifecycle (`T19`), so this controller
    // has to hear about it. Registered here and removed in [dispose], beside
    // the registration `ConnectionController` already makes for its own
    // cadence: one observer per controller, and the app builds exactly one of
    // each.
    WidgetsBinding.instance.addObserver(this);
    _syncGreeting();
    // The badge and the list start from what the queue actually holds, so a
    // cold start that finds rows left by a force-kill shows them before any
    // drain runs (`T18`, `FR-MD06`). Fire-and-forget: opening the database must
    // not hold the frame that builds the first screen.
    unawaited(refreshQueue());
  }

  static const String _greetingId = 'greeting';

  /// The cadence of the hidden probe (`T19`).
  ///
  /// The same 20 s [ConnectionController] uses for its own re-probe while the
  /// app is visible, and deliberately the same number rather than a second
  /// opinion about how often to ask the backend: the two cadences never run at
  /// the same time — the connection's own stops when the app leaves the
  /// foreground, this one only exists while the app is away — so equal
  /// intervals mean a transition in either direction never changes how often
  /// the backend is asked.
  static const Duration _hiddenProbeInterval = Duration(seconds: 20);

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

  /// The drain window's foreground service (`T19`), through which this class
  /// keeps the app's process scheduled while the app is not in the foreground.
  ///
  /// Nothing here knows it is a notification: the port is "open or close the
  /// window, and say how much is still owed".
  late final DrainService _drainService;

  /// The window's transitions, chained one after another.
  ///
  /// A start and the update that follows it must not overtake each other on the
  /// method channel: the count of a window that does not exist yet would be
  /// lost, and a stop that overtook an update would leave a notification
  /// describing work that is already done.
  Future<void> _drainWindowChain = Future<void>.value();

  /// True while this run has asked the platform to hold the drain window open.
  ///
  /// It records that the window was **asked for**, not that the platform
  /// granted it: the service reports its own failures, and a refused window is
  /// a log line rather than a state this class can act on. Keeping the flag on
  /// the request side is also what stops a refused start from being retried on
  /// every queue change, which would be noise, not diligence.
  bool _drainWindowOpen = false;

  /// True once this run has asked for the notification permission, granted or
  /// not: Android shows that dialog once per install, and asking again while
  /// the answer is still pending would be a second dialog over the first.
  bool _notificationPermissionAsked = false;

  /// True while the app is not in the foreground (`T19`).
  bool _inBackground = false;

  /// The hidden probe cadence (`T19`), or null when none is running.
  ///
  /// Runs only while the app is not in the foreground **and** the queue still
  /// owes the operator something. [_syncHiddenProbe] is the only thing that
  /// schedules or drops it, and at most one is ever live.
  Timer? _hiddenProbeTimer;

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
      // Nothing is owed to anybody, so a window held open by a previous
      // profile is closed here rather than left describing a queue that is no
      // longer this app's — and with nothing owed there is also nothing left to
      // ask the backend about, so the hidden cadence stops too.
      unawaited(_syncDrainWindow());
      _syncHiddenProbe();
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
    // Two things follow the projection, both fire-and-forget because neither
    // may hold the frame that asked for the queue: the permission the drain
    // window needs, which is asked while the app can still show the dialog, and
    // the window itself, whose count is a function of the queue and nothing
    // else (`T19`).
    _maybeRequestNotificationPermission();
    unawaited(_syncDrainWindow());
    // The projection is also what tells the hidden cadence whether it is still
    // owed work: a drain that emptied the queue while the app was away stops it
    // here, without waiting for the next tick.
    _syncHiddenProbe();
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
        result: outcome.result,
      );
    }
    logEvent('conversation', {
      'action': 'resolved',
      'status': outcome.status.name,
      'operation': outcome.evidence?.operationKey,
      'pending': _pending != null,
      'advanced': advanced,
    });
    // The conversation is one of the queue's writers, so it is one of the
    // places that must re-project it. A queued outcome is the only path in
    // this class that **adds** a durable row, and before this refresh the
    // projection had no writer on exactly that path. Measured on `TFY-LX3`,
    // the operator queued one `pago` offline (`[umlive][outbox]
    // action=enqueue id=6 seq=1 …`), the durable row existed, and yet
    // `queuedCount` stayed 0 — no badge on the queue action, no
    // notification-permission request, no drain window and no hidden
    // re-probe, so `T19`'s acceptance run never exercised the OEM at all
    // (`[umlive][service]` appears zero times in that capture). The projection
    // silently disabled all four.
    //
    // It runs before the turn's own notification for a reason beyond the
    // rebuild: the notification permission request hangs off a non-empty
    // projection (`_maybeRequestNotificationPermission`), so the projection
    // must be re-read here and now, while the app is still visible, or the
    // dialog waits for another writer that may never come. Nothing else
    // changes: no new timer, no polling of the database, and the durable row
    // stays the only source of truth.
    if (outcome.status == TurnStatus.queued) {
      await refreshQueue();
    }
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

  /// The lifecycle half of the drain window (`T19`).
  ///
  /// The app is not in the foreground from `inactive` onwards, and `inactive`
  /// is deliberate rather than sloppy: it is the first state that says the
  /// operator has stopped looking, and the drain must already be protected by
  /// the time the process is a candidate for the OEM's killer. `resumed` is the
  /// only state that ends the window, because that is the one where the app is
  /// visible again and being scheduled on its own merits.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _inBackground = false;
        // The permission dialog belongs to a visible app, so a queue that first
        // became non-empty while the app was away is asked about here instead.
        _maybeRequestNotificationPermission();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _inBackground = true;
    }
    // The cadence belongs to the work the app owes, so it is re-decided on
    // exactly the transition that changed whether the app is looking: on the
    // way out it starts when the queue is non-empty, and on the way back in it
    // stops, because the connection's own cadence takes over again.
    _syncHiddenProbe();
    unawaited(_syncDrainWindow());
  }

  /// Keeps the hidden probe in step with what the app owes (`T19`).
  ///
  /// **The rule:** while the app is hidden, the probe cadence belongs to the
  /// work the app owes. Visible, the connection's own timer asks the backend on
  /// its slow cadence (unchanged by this method). Hidden with an empty queue,
  /// nothing is asked at all — there is no promise to keep, so a request every
  /// 20 s would be work nobody asked for. Hidden with a non-empty queue, the
  /// app keeps asking every [_hiddenProbeInterval] until the queue empties or
  /// the app comes back.
  ///
  /// **Why it exists.** [ConnectionController] cancels its re-probe timer as
  /// soon as the app leaves the foreground, which is right for a *visible* app:
  /// polling behind the operator's back is the wrong default. But the drain
  /// window ([DrainService]) keeps the process scheduled on purpose while the
  /// app is hidden, and without this timer that scheduling is worth nothing:
  /// the process survives and nothing ever asks the backend again, so an
  /// in-flight send can finish and no new drain can start until the app is
  /// resumed. A notification reading *"1 operación pendiente, esperando
  /// conexión."* is only honest if the app is still asking whether the
  /// connection came back — otherwise the window describes a wait that is not
  /// being worked on. `T19`'s acceptance check is explicit about this: it
  /// validates with the screen **off**.
  ///
  /// **What it deliberately does not do.** It does not touch reachability: the
  /// probe is the only thing that decides the state, and the drain still starts
  /// from the transition that probe causes through the existing connection
  /// listener. It does not add a second way to reach the backend either — it
  /// calls the same public `probeStored` the Connect screen's retry calls. And
  /// it cannot force the platform to run it: **Android may throttle background
  /// work regardless**, which is exactly the OEM problem `T19` exists for — the
  /// window and this cadence are the app's honest best effort, not a guarantee.
  ///
  /// One log line per start and per stop, never one per tick: each tick's own
  /// evidence is the `[umlive][probe]` line `probeStored` already writes, so a
  /// line here would only duplicate it.
  void _syncHiddenProbe() {
    final wanted = _inBackground && _queue.isNotEmpty;
    if (!wanted) {
      final timer = _hiddenProbeTimer;
      if (timer == null) return;
      timer.cancel();
      _hiddenProbeTimer = null;
      logEvent('outbox', <String, Object?>{
        'action': 'hidden_probe',
        'result': 'stopped',
        'count': _queue.length,
      });
      return;
    }
    if (_hiddenProbeTimer != null) return;
    _hiddenProbeTimer = Timer.periodic(_hiddenProbeInterval, (_) {
      // Fire-and-forget, the same contract the connection's own cadence keeps:
      // the timer must not queue probes behind each other, and `probeStored`
      // already owns every failure mode as a state.
      unawaited(_connection.probeStored());
    });
    logEvent('outbox', <String, Object?>{
      'action': 'hidden_probe',
      'result': 'started',
      'count': _queue.length,
      'intervalSeconds': _hiddenProbeInterval.inSeconds,
    });
  }

  /// Keeps the drain window equal to what the app actually owes (`T19`).
  ///
  /// One decision point, called from the only two things that can change the
  /// answer: the app's lifecycle and the queue's own projection
  /// ([refreshQueue]). That is what keeps the window from being open while the
  /// app is visible — where the platform schedules it anyway — and, more
  /// importantly, from outliving the work: a notification that stays after the
  /// last item was sent is a lie about work still owed.
  Future<void> _syncDrainWindow() {
    _drainWindowChain = _drainWindowChain.then((_) => _applyDrainWindow());
    return _drainWindowChain;
  }

  Future<void> _applyDrainWindow() async {
    // Read once, so the decision and the copy describe the same queue.
    final count = _queue.length;
    final wanted = _inBackground && count > 0;
    try {
      if (!wanted) {
        if (!_drainWindowOpen) return;
        _drainWindowOpen = false;
        await _drainService.stop();
        return;
      }
      final title = _l10n.appTitle;
      final body = _l10n.drainNotificationBody(count);
      if (_drainWindowOpen) {
        // A drain, a cancel or a retry moved the count while the window was
        // open: the notification follows the queue instead of describing a
        // queue that no longer exists.
        await _drainService.update(title: title, body: body, count: count);
        return;
      }
      _drainWindowOpen = true;
      await _drainService.start(title: title, body: body, count: count);
    } on Object catch (error) {
      // Every failure of the window is non-fatal to the conversation. The
      // drain lives in Dart; the service only keeps it scheduled, so an
      // operator who cannot be given a window still gets their answers.
      logEvent('service', {
        'action': 'window',
        'result': 'failed',
        'reason': error.runtimeType.toString(),
      });
    }
  }

  /// Asks for the notification permission once per run, while the app can still
  /// show the dialog (`T19`).
  ///
  /// The moment is the queue's first non-empty projection of this run: from
  /// Android 13 on, the dialog needs a visible app to be attached to, and this
  /// is the moment the app knows it has something to report. A queue that first
  /// fills up while the app is away is asked about on the way back in.
  ///
  /// **The honest limit of this feature:** if the permission is denied the
  /// service still runs and still keeps the process scheduled for the drain —
  /// what is lost is only the operator's ability to see the window, not the
  /// work it protects. That is why a denial is a log line and a continuation
  /// rather than a refusal to drain.
  void _maybeRequestNotificationPermission() {
    if (_notificationPermissionAsked) return;
    if (_queue.isEmpty) return;
    if (_inBackground) return;
    _notificationPermissionAsked = true;
    unawaited(_requestNotificationPermission());
  }

  Future<void> _requestNotificationPermission() async {
    try {
      final status = await Permission.notification.request();
      logEvent('service', {
        'action': 'permission',
        'result': status.isGranted ? 'granted' : 'denied',
      });
    } on Object catch (error) {
      // A platform that cannot be asked is not a platform that refuses: the
      // window opens either way and only its visibility is in doubt.
      logEvent('service', {
        'action': 'permission',
        'result': 'failed',
        'reason': error.runtimeType.toString(),
      });
    }
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
    WidgetsBinding.instance.removeObserver(this);
    // The hidden cadence goes first: a timer that survived this controller
    // would keep asking the backend on behalf of a conversation that is gone.
    _hiddenProbeTimer?.cancel();
    _hiddenProbeTimer = null;
    // The window belongs to this conversation: one that is gone must not leave
    // a foreground service claiming a queue nobody is draining any more.
    unawaited(_drainService.stop());
    super.dispose();
  }
}
