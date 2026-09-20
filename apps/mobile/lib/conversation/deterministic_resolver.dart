/// The deterministic resolver: the read path (`T12`).
///
/// **This is the only way an utterance becomes an operation call.** `FR-MC04`
/// used to describe an offline branch that matched locally while a model
/// absorbed phrasing variety online; the model is gone from this product, so
/// the local matcher was promoted to the resolver, used identically with the
/// radio on or off. There is no online branch and no second resolver to fall
/// back to.
///
/// What that costs is honesty about the matcher's limits, and this class pays
/// it in the conversation itself. When it cannot resolve an utterance it names
/// what it could not resolve — that no known entity was named, or that more
/// than one was, or that the intent was not understood, or that the backend
/// publishes no read operation for the entity it did understand — instead of
/// picking the closest guess. A resolver that guesses looks decisive and is
/// wrong; one that names its failure can be fixed.
///
/// **It never invents a route, verb or field name** (`FR-MA03`). Operations
/// come from [EntityModel.roleKeys] and are looked up with
/// [ApiRegistry.operation]; path parameter names come from
/// [ApiOperation.pathParameterNames]. Nothing here knows the word `cliente`,
/// the string `GET` or the field `id`. It also never touches the network,
/// storage or the connection: the only thing it can reach out with is the
/// [OperationExecutor] it is handed.
///
/// **The write paths live here too** (`T13`, `T13b`). A create utterance opens
/// a draft and fills it one field at a time (`FR-MC02`), reads the complete
/// record back and only then submits, on an affirmative (`FR-MC03`); nothing is
/// executed on the turn that started it. A delete names one target, restates its
/// identity and only then issues the `DELETE`, on an affirmative (`FR-MC05`),
/// and its target is never inferred from an ambiguous utterance — resolving one
/// by name (`FR-MC06`) is a Should Have this build does not implement. Updates
/// are **not** in this build either: an update verb is refused rather than
/// answered by the read path, because an update needs the record read first and
/// is its own task.
library;

import '../core/log.dart';
import '../core/text_fold.dart';
import '../l10n/app_localizations.dart';
import '../openapi/registry.dart';
import '../presentation/discovered_scope.dart';
import 'field_value.dart';
import 'operation_executor.dart';
import 'operation_resolver.dart';
import 'pending_write.dart';
import 'spanish_language.dart';
import 'turn.dart';

/// The shipped [OperationResolver]: the read path of `T12` and the write paths
/// of `T13` and `T13b`, in one class.
///
/// Stateless by construction: every call gets its utterance, registry,
/// executor and localizations as parameters, so there is nothing to reset
/// between turns and no way for one resolution to leak into the next.
class DeterministicOperationResolver implements OperationResolver {
  const DeterministicOperationResolver();

  /// The three values the `[umlive][resolver]` line's `result` field takes.
  ///
  /// `read` means the utterance was resolved into a read operation — whether
  /// the call then succeeded or not, because the `reason` on the same line
  /// says which. `write` means it was resolved into a write conversation — the
  /// create of `T13` or the delete of `T13b` — and the `intent` on the same
  /// line says which of the two. `not_understood` means nothing was resolved
  /// and no call was made.
  static const String _resultRead = 'read';
  static const String _resultWrite = 'write';
  static const String _resultNotUnderstood = 'not_understood';

  /// The `intent` the create path logs: the draft is a create, whether the turn
  /// starts it, fills a field or confirms it. The `phase` on the same line says
  /// which part of that conversation the turn is.
  static const String _intentCreate = 'create';

  /// The `intent` the delete path logs (`T13b`): the turn names one record and
  /// confirms it (`FR-MC05`). A delete carries no [WritePhase] of its own,
  /// because nothing about it is collected, so its turns log the constant
  /// below as their phase instead.
  static const String _intentDelete = 'delete';

  /// The `phase` every delete turn logs. A delete carries no
  /// [WritePhase] — there is nothing to collect — so this is a constant and not
  /// a draft field; it is `confirming` because identified-and-confirmed is the
  /// only stage a delete is ever in, which keeps the log column comparable with
  /// a create's.
  static const String _phaseConfirming = 'confirming';

  @override
  Future<ResolverOutcome> resolve({
    required String utterance,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
    PendingWrite? pending,
  }) async {
    // A draft in flight means this utterance is an answer to the conversation
    // it belongs to — a field value, an affirmative or a negative — and never
    // a new command. The draft is the controller's; this class only continues
    // it.
    if (pending != null) {
      return _continueWrite(
        utterance: utterance,
        pending: pending,
        registry: registry,
        executor: executor,
        l10n: l10n,
      );
    }

    // One pass of the one tokenizer, both projections: the folded tokens the
    // matcher compares, and the spans the create path rebuilds raw text from.
    final spans = utteranceTokenSpans(utterance);
    final tokens = <String>[for (final span in spans) span.folded];
    final length = utterance.length;

    // Entity match. Every entity that matches contributes exactly one
    // candidate, so a tie below is a tie between two different entities.
    final matches = <_EntityMatch>[];
    for (final entity in registry.entities) {
      final match = _bestMatch(entity, tokens);
      if (match != null) matches.add(match);
    }

    if (matches.isEmpty) {
      return _finish(
        utteranceLength: length,
        result: _resultNotUnderstood,
        replyText: l10n.conversationNotUnderstoodNoEntity(
          joinEntityNames(l10n, _knownEntityNames(registry)),
        ),
        status: TurnStatus.failed,
        reason: 'no_entity',
      );
    }

    matches.sort(_byScore);
    final best = matches.first;
    final top = matches
        .where(
          (candidate) =>
              !candidate.overlaps(best) ||
              (candidate.tokenCount == best.tokenCount &&
                  candidate.foldLength == best.foldLength),
        )
        .toList();
    if (top.length > 1) {
      // Two reasons land here, and both mean the same thing: the turn cannot
      // answer with one name. A match that overlaps the best window is another
      // reading of the same mention — a longer name swallowing a shorter one,
      // or two entities the very same words fit. A match that sits somewhere
      // else in the utterance is a second mention the operator actually made,
      // and it is not tied on score: the longer folded name simply won. In
      // either case, choosing one of them would drop half of what was asked
      // for and call it an answer, so the turn names both and stops.
      return _finish(
        utteranceLength: length,
        result: _resultNotUnderstood,
        replyText: l10n.conversationNotUnderstoodAmbiguous(
          joinEntityNames(
            l10n,
            top.map((match) => lowerFirst(match.entity.name)).toList(),
          ),
        ),
        status: TurnStatus.failed,
        reason: 'ambiguous',
      );
    }

    final match = best;
    final entity = match.entity;
    final name = lowerFirst(entity.name);

    // A delete is the destructive conversation (`FR-MC05`): it names its one
    // target, reads the identity back and only then issues the `DELETE`. It is
    // checked before a create so a delete verb can never open a draft instead,
    // and before anything reaches the read path.
    if (tokens.any(deleteTriggers.contains)) {
      return _beginDelete(
        utteranceLength: length,
        tokens: tokens,
        entity: entity,
        name: name,
        registry: registry,
        l10n: l10n,
      );
    }

    // An update is a write this build does not implement, and it must not fall
    // through to the read path: today "modificá el cliente 1" would find the
    // `get` role and *read* the record it was asked to change, which is a lie
    // about what the app did. It names what it did not understand instead. An
    // update needs the record read first, so it is its own task.
    if (tokens.any(updateTriggers.contains)) {
      return _finish(
        utteranceLength: length,
        result: _resultNotUnderstood,
        replyText: l10n.conversationNotUnderstoodIntent(name),
        status: TurnStatus.failed,
        entity: name,
        reason: 'write_not_implemented',
      );
    }

    // A create opens a draft and asks, one field at a time. Nothing is
    // executed on this turn (`FR-MC02`, `FR-MC03`).
    if (tokens.any(createTriggers.contains)) {
      return _beginWrite(
        utterance: utterance,
        utteranceLength: length,
        spans: spans,
        tokens: tokens,
        match: match,
        entity: entity,
        name: name,
        registry: registry,
        l10n: l10n,
      );
    }

    final plan = _classifyIntent(entity, tokens, match);
    if (plan.intent == _Intent.unknown) {
      return _finish(
        utteranceLength: length,
        result: _resultNotUnderstood,
        replyText: l10n.conversationNotUnderstoodIntent(name),
        status: TurnStatus.failed,
        entity: name,
        reason: 'intent',
      );
    }
    final intent = plan.intent.name;

    // The operation comes from the role the entity actually publishes. A
    // missing role and an operation with no declared path parameter name are
    // the same kind of problem: there is no way to call what was asked for.
    final roleKey = plan.intent == _Intent.get
        ? entity.roleKeys[EntityRole.get]
        : entity.roleKeys[EntityRole.list];
    final operation = roleKey == null ? null : registry.operation(roleKey);
    final parameterName = plan.intent != _Intent.get
        ? null
        : (operation == null || operation.pathParameterNames.isEmpty)
        ? null
        : operation.pathParameterNames.first;

    if (operation == null ||
        (plan.intent == _Intent.get && parameterName == null)) {
      return _finish(
        utteranceLength: length,
        result: _resultNotUnderstood,
        replyText: l10n.conversationNotUnderstoodNoReadOperation(name),
        status: TurnStatus.failed,
        intent: intent,
        entity: name,
        reason: 'no_read_operation',
      );
    }

    final recordId = plan.recordId;
    final bound = parameterName != null && recordId != null
        ? <String, String>{parameterName: recordId}
        : const <String, String>{};

    final result = await executor.execute(
      operation: operation,
      pathParameters: bound,
    );
    final evidence = OperationEvidence.fromResult(result);

    // A cached read is branched on **before** `succeeded` — and after `queued`,
    // which a read can never be, because the outbox never queues a safe method.
    // `fromCache` means a real answer to the operator that came from storage
    // instead of from the backend (`FR-MD05`), so `succeeded` is false for it;
    // the same ordering discipline a queued write follows, for the same reason:
    // an answer that did not come from the backend must never be reported as if
    // it had. A cached result that arrived without its age is treated as the
    // failure it is, so a remembered answer can never render as a live one.
    final cacheAge = result.fromCache ? result.cacheAge : null;

    if (cacheAge == null && !result.succeeded) {
      // The call ran and the backend did not answer correctly. `T22` replaces
      // this sentence with one derived from the status and the `errors` keys;
      // the evidence travels with the turn either way.
      return _finish(
        utteranceLength: length,
        result: _resultRead,
        replyText: l10n.conversationReadFailed(name),
        status: TurnStatus.failed,
        intent: intent,
        entity: name,
        operation: operation.key,
        reason: 'read_failed',
        evidence: evidence,
      );
    }

    // The count is computed here, from the full body the app is answering
    // from — the backend's or the remembered one, the same way either way: the
    // generated API publishes no count endpoint (`FR-ME02`).
    final body = result.decodedBody;
    int? recordCount;
    if (plan.intent == _Intent.get) {
      if (body is Map) recordCount = 1;
    } else if (body is List) {
      recordCount = body.length;
    }

    if (recordCount == null) {
      return _finish(
        utteranceLength: length,
        result: _resultRead,
        replyText: l10n.conversationReadUnreadable(name),
        status: TurnStatus.failed,
        intent: intent,
        entity: name,
        operation: operation.key,
        reason: 'unreadable',
        evidence: evidence,
      );
    }

    // A remembered answer carries its age, as the UX spec's *Stale / cached*
    // row requires: it is a real answer and it says how old it is
    // (`FR-MD05`). Both sentences come from the ARB and the app ships exactly
    // one locale (`l10n.yaml`), which is why a plain space is the separator
    // between them and no locale-specific joiner is needed.
    final answer = l10n.conversationCountAnswer(
      recordCount,
      name,
      pluralizeSpanishNoun(name),
    );

    return _finish(
      utteranceLength: length,
      result: _resultRead,
      replyText: cacheAge == null
          ? answer
          : '$answer ${l10n.conversationCachedAge(cacheAge.inMinutes)}',
      status: TurnStatus.resolved,
      intent: intent,
      entity: name,
      operation: operation.key,
      count: recordCount,
      // Present only on a cached answer, so a live read's line is exactly the
      // one it always was.
      cache: cacheAge == null ? null : true,
      ageMs: cacheAge?.inMilliseconds,
      evidence: evidence,
    );
  }

  /// Writes the one `[umlive][resolver]` line this resolution gets and builds
  /// its outcome, so every return above is logged the same way.
  ///
  /// [cache] and [ageMs] are the two columns `T17` adds, and they are written
  /// only by an answer that came from the read cache (`FR-MD05`): they are
  /// absent on a live answer rather than false.
  ///
  /// The utterance's text is never logged — only its length, the same
  /// discipline `T11` applies and `log.dart` applies to the bearer token. A
  /// transcription is the operator's own words and does not belong in a
  /// device log. The write path keeps the same rule for what it captures:
  /// only [valueLength] is loggable, never the value, and [field] names the
  /// field being asked for without carrying what was put into it. The delete
  /// path keeps it for its one target too: the identifier named by the
  /// operator is never a field of this line, and it reaches the log only
  /// through the executor's own `path=` line, which is a protocol-level fact —
  /// exactly what the read path's `get` already does with the id it binds.
  ResolverOutcome _finish({
    required int utteranceLength,
    required String result,
    required String replyText,
    required TurnStatus status,
    String? intent,
    String? entity,
    String? operation,
    int? count,
    bool? cache,
    int? ageMs,
    String? phase,
    String? field,
    bool? extracted,
    int? valueLength,
    String? reason,
    OperationEvidence? evidence,
    PendingWrite? pending,
  }) {
    logEvent('resolver', <String, Object?>{
      'result': result,
      'utteranceLength': utteranceLength,
      'intent': ?intent,
      'entity': ?entity,
      'operation': ?operation,
      'count': ?count,
      // `FR-MD05`: a cached read is a real answer and the log has to be able to
      // tell it from a live one without reading the sentence.
      'cache': ?cache,
      'age_ms': ?ageMs,
      'phase': ?phase,
      'field': ?field,
      'extracted': ?extracted,
      'valueLength': ?valueLength,
      'reason': ?reason,
    });
    return ResolverOutcome(
      replyText: replyText,
      status: status,
      evidence: evidence,
      pending: pending,
    );
  }

  /// Opens a create draft for [entity] and returns the turn that shows it: the
  /// first missing field's question, or the read-back when nothing is missing.
  ///
  /// Nothing is executed here. `FR-MC03` requires an affirmative before any
  /// `POST`, and `FR-MC02` requires the complete body, so the most this turn
  /// does is fill in one value the operator volunteered in the §5.1 shape and
  /// ask for the rest, one field at a time.
  ResolverOutcome _beginWrite({
    required String utterance,
    required int utteranceLength,
    required List<UtteranceToken> spans,
    required List<String> tokens,
    required _EntityMatch match,
    required EntityModel entity,
    required String name,
    required ApiRegistry registry,
    required AppLocalizations l10n,
  }) {
    final roleKey = entity.roleKeys[EntityRole.create];
    final operation = roleKey == null ? null : registry.operation(roleKey);
    final requiredFields = entity.requiredWritableFields;

    // "A required body the app cannot fill": the document marks the body as
    // required (or lists required properties) while the entity carries no
    // required writable field at all. There is nothing to ask for and nothing
    // honest to send, so the turn refuses instead of posting an empty body.
    final declaresRequiredBody =
        operation != null &&
        (operation.requestBodyRequired ||
            (operation.requestBody?.required.isNotEmpty ?? false));

    if (operation == null ||
        (requiredFields.isEmpty && declaresRequiredBody)) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultNotUnderstood,
        replyText: l10n.conversationWriteNoCreateOperation(name),
        status: TurnStatus.failed,
        intent: _intentCreate,
        entity: name,
        reason: 'no_create_operation',
      );
    }

    var draft = PendingCreate(
      entityName: name,
      operationKey: operation.key,
      requiredFields: requiredFields,
      values: const <String, String>{},
      asking: requiredFields.isEmpty ? null : requiredFields.first,
      phase: requiredFields.isEmpty
          ? WritePhase.confirming
          : WritePhase.collecting,
    );

    // Initial value extraction, deliberately narrow: only the §5.1 shape, only
    // for a field this conversation can dictate at all, and only when the
    // phrase is really there. Every other phrasing is asked for rather than
    // guessed at.
    var extracted = false;
    var valueLength = 0;
    final first = requiredFields.isEmpty ? null : requiredFields.first;
    if (first != null && isCollectibleByVoice(first)) {
      final rawValue = _extractInitialValue(utterance, spans, tokens, match);
      if (rawValue != null) {
        final converted = convertFieldValue(first, rawValue);
        // The free-text phrase is only the right value for a textual field: an
        // integer or a boolean field would reject it, and a relation is not
        // asked for at all. A `String` result is exactly that check, so the
        // extraction never fills a field whose value is not text.
        if (converted is FieldValueOk && converted.value is String) {
          final rest = requiredFields.skip(1).toList();
          draft = draft.withValue(
            first.name,
            rawValue.trim(),
            nextAsking: rest.isEmpty ? null : rest.first,
          );
          extracted = true;
          valueLength = rawValue.trim().length;
        }
      }
    }

    final missing = draft.missing;
    final replyText = missing.isEmpty
        ? l10n.conversationWriteReadBackCreate(name)
        : l10n.conversationWriteAskField(missing.first.name);

    return _finish(
      utteranceLength: utteranceLength,
      result: _resultWrite,
      replyText: replyText,
      status: TurnStatus.resolved,
      intent: _intentCreate,
      entity: name,
      operation: operation.key,
      phase: draft.phase.name,
      field: draft.asking?.name,
      extracted: extracted,
      valueLength: extracted ? valueLength : null,
      pending: draft,
    );
  }

  /// Opens the destructive conversation for [entity] and returns the turn that
  /// reads its target's identity back (`FR-MC05`).
  ///
  /// The target is the **first numeric token** and nothing else. A delete is
  /// never inferred: with no numeric token there is no target, and the turn says
  /// so instead of guessing one. Resolving a target by name is `FR-MC06`, a
  /// Should Have this build does not implement. Nothing is executed here — the
  /// `DELETE` waits for an affirmative (`FR-MC03`, `FR-MC05`) — and the
  /// identifier is never logged, the same discipline the read path applies to
  /// the utterance text: it reaches the log only through the executor's own
  /// `path=` line.
  ResolverOutcome _beginDelete({
    required int utteranceLength,
    required List<String> tokens,
    required EntityModel entity,
    required String name,
    required ApiRegistry registry,
    required AppLocalizations l10n,
  }) {
    // The operation comes from the role the entity actually publishes, never
    // from an assembled route (`FR-MA03`). A missing role and a role the
    // registry does not carry are the same kind of problem: there is nothing to
    // delete through.
    final roleKey = entity.roleKeys[EntityRole.delete];
    final operation = roleKey == null ? null : registry.operation(roleKey);
    if (operation == null) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultNotUnderstood,
        replyText: l10n.conversationDeleteNoOperation(name),
        status: TurnStatus.failed,
        intent: _intentDelete,
        entity: name,
        reason: 'no_delete_operation',
      );
    }

    String? recordId;
    for (final token in tokens) {
      if (_isNumeric(token)) {
        recordId = token;
        break;
      }
    }
    if (recordId == null) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultNotUnderstood,
        replyText: l10n.conversationDeleteNoTarget(name),
        status: TurnStatus.failed,
        intent: _intentDelete,
        entity: name,
        reason: 'delete_no_target',
      );
    }

    // A delete operation that declares no path parameter cannot address a
    // single record, so there is nothing honest to call.
    if (operation.pathParameterNames.isEmpty) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultNotUnderstood,
        replyText: l10n.conversationDeleteNoTarget(name),
        status: TurnStatus.failed,
        intent: _intentDelete,
        entity: name,
        reason: 'no_delete_parameter',
      );
    }

    final draft = PendingDelete(
      entityName: name,
      operationKey: operation.key,
      recordId: recordId,
    );

    // The read-back restates the identity of the target and nothing is sent on
    // this turn. `FR-MC05`: the operator has to accept it before the record is
    // destroyed.
    return _finish(
      utteranceLength: utteranceLength,
      result: _resultWrite,
      replyText: l10n.conversationDeleteReadBack(recordId, name),
      status: TurnStatus.resolved,
      intent: _intentDelete,
      entity: name,
      operation: operation.key,
      phase: _phaseConfirming,
      pending: draft,
    );
  }

  /// The operator's own words for the first required field, when the utterance
  /// carries them in the §5.1 shape.
  ///
  /// The shape is *Agregá a Juan Pérez como cliente*: a create trigger, the
  /// value, a connector from [createValueConnectors], then the entity mention.
  /// The window is deliberately narrow — the connector must sit immediately
  /// before the entity mention, and at least one token must sit between the
  /// trigger and the connector. The text is rebuilt from
  /// [utteranceTokenSpans] offsets, so `Juan Pérez` comes back with its accents
  /// and capitals. One leading `a` is skipped, because the §5.1 sentence
  /// carries Spanish's personal accusative marker before a person's name and
  /// that is grammar, not part of the value; nothing else is trimmed, so a name
  /// that begins with another word keeps it. Returns null when the shape is
  /// absent.
  static String? _extractInitialValue(
    String utterance,
    List<UtteranceToken> spans,
    List<String> tokens,
    _EntityMatch match,
  ) {
    final connectorIndex = match.windowStart - 1;
    if (connectorIndex < 0) return null;
    if (!createValueConnectors.contains(tokens[connectorIndex])) return null;

    // The nearest create trigger before the connector: the value is what sits
    // between the two.
    var triggerIndex = -1;
    for (var index = connectorIndex - 1; index >= 0; index--) {
      if (createTriggers.contains(tokens[index])) {
        triggerIndex = index;
        break;
      }
    }
    if (triggerIndex == -1 || connectorIndex - triggerIndex < 2) return null;

    var first = triggerIndex + 1;
    if (first < connectorIndex && tokens[first] == 'a') first++;
    if (first >= connectorIndex) return null;

    return utterance.substring(
      spans[first].start,
      spans[connectorIndex - 1].end,
    );
  }

  /// Continues the write [pending] describes: the utterance is an answer to the
  /// conversation, never a new command.
  ///
  /// The sealed type is switched on rather than its members probed, so a third
  /// write would not compile until it were handled — the same discipline
  /// `turn.dart` applies to turns. Both writes read an affirmative and a
  /// negative the same way ([_isAffirmative], [_isNegative]) and settle in the
  /// same three shapes; only a create is assembled field by field.
  Future<ResolverOutcome> _continueWrite({
    required String utterance,
    required PendingWrite pending,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
  }) async {
    final tokens = utteranceTokens(utterance);
    final length = utterance.length;

    switch (pending) {
      // A delete was identified when it opened, so there is nothing to collect
      // here: the utterance is an affirmative, a negative or neither
      // (`FR-MC05`).
      case PendingDelete delete:
        return _continueDelete(
          utteranceLength: length,
          tokens: tokens,
          pending: delete,
          registry: registry,
          executor: executor,
          l10n: l10n,
        );

      case PendingCreate create:
        final entityName = create.entityName;
        final phase = create.phase.name;

        if (create.phase == WritePhase.confirming) {
          if (_isAffirmative(tokens)) {
            return _submitWrite(
              utteranceLength: length,
              pending: create,
              registry: registry,
              executor: executor,
              l10n: l10n,
            );
          }
          if (_isNegative(tokens)) {
            // A cancel is neither a failure nor a success: nothing was sent,
            // and the draft is dropped because there is nothing left to send.
            return _finish(
              utteranceLength: length,
              result: _resultWrite,
              replyText: l10n.conversationWriteCancelled,
              status: TurnStatus.resolved,
              intent: _intentCreate,
              entity: entityName,
              operation: create.operationKey,
              phase: phase,
              pending: null,
            );
          }
          // Neither an affirmative nor a negative: the read-back stands and
          // the draft is kept. The turn settled, so it is resolved and not
          // failed.
          return _finish(
            utteranceLength: length,
            result: _resultWrite,
            replyText: l10n.conversationWriteAwaitingConfirmation,
            status: TurnStatus.resolved,
            intent: _intentCreate,
            entity: entityName,
            operation: create.operationKey,
            phase: phase,
            pending: create,
          );
        }

        // Collecting: the whole utterance is the answer to the one field being
        // asked for. `PendingCreate` sets `asking` for every collecting draft,
        // so the phase and the field cannot disagree.
        final field = create.asking!;
        final converted = convertFieldValue(field, utterance);
        if (converted is! FieldValueOk) {
          // One clear sentence, not two: the value was not accepted and the
          // same field is asked for again. The draft is untouched.
          return _finish(
            utteranceLength: length,
            result: _resultWrite,
            replyText: l10n.conversationWriteFieldInvalid(field.name),
            status: TurnStatus.failed,
            intent: _intentCreate,
            entity: entityName,
            operation: create.operationKey,
            phase: phase,
            field: field.name,
            valueLength: utterance.trim().length,
            reason: 'invalid_field',
            pending: create,
          );
        }

        final rest = create.missing
            .where((candidate) => candidate.name != field.name)
            .toList();
        final nextDraft = create.withValue(
          field.name,
          utterance.trim(),
          nextAsking: rest.isEmpty ? null : rest.first,
        );

        if (nextDraft.isComplete) {
          // The record is complete. It is read back in domain language and
          // waits (`FR-MC03`); nothing is submitted on this turn.
          return _finish(
            utteranceLength: length,
            result: _resultWrite,
            replyText: l10n.conversationWriteReadBackCreate(entityName),
            status: TurnStatus.resolved,
            intent: _intentCreate,
            entity: entityName,
            operation: create.operationKey,
            phase: nextDraft.phase.name,
            valueLength: utterance.trim().length,
            pending: nextDraft,
          );
        }

        final next = nextDraft.missing.first;
        return _finish(
          utteranceLength: length,
          result: _resultWrite,
          replyText: l10n.conversationWriteAskField(next.name),
          status: TurnStatus.resolved,
          intent: _intentCreate,
          entity: entityName,
          operation: create.operationKey,
          phase: nextDraft.phase.name,
          field: next.name,
          valueLength: utterance.trim().length,
          pending: nextDraft,
        );
    }
  }

  /// Whether [tokens] carry an affirmative (`FR-MC03`).
  ///
  /// Shared by both writes: a create and a delete are confirmed the same way,
  /// and the band's *Confirmar* control submits one of these words as an
  /// ordinary utterance through the same resolution path as speech.
  static bool _isAffirmative(List<String> tokens) =>
      tokens.any(affirmativeAnswers.contains);

  /// Whether [tokens] carry a negative (`FR-MC03`), shared by both writes the
  /// same way [_isAffirmative] is.
  static bool _isNegative(List<String> tokens) =>
      tokens.any(negativeAnswers.contains);

  /// Continues a delete waiting for its affirmative (`FR-MC05`).
  ///
  /// Three outcomes, the same shape as a create's confirmation: an affirmative
  /// issues the `DELETE`, a negative reports that nothing was sent, and
  /// anything else leaves the read-back standing.
  Future<ResolverOutcome> _continueDelete({
    required int utteranceLength,
    required List<String> tokens,
    required PendingDelete pending,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
  }) async {
    final entityName = pending.entityName;

    if (_isAffirmative(tokens)) {
      return _submitDelete(
        utteranceLength: utteranceLength,
        pending: pending,
        registry: registry,
        executor: executor,
        l10n: l10n,
      );
    }

    if (_isNegative(tokens)) {
      // A cancelled delete sent nothing, so it is neither a failure nor a
      // success and there is nothing left to send.
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationWriteCancelled,
        status: TurnStatus.resolved,
        intent: _intentDelete,
        entity: entityName,
        operation: pending.operationKey,
        phase: _phaseConfirming,
        pending: null,
      );
    }

    // Neither an affirmative nor a negative: the read-back stands and the
    // target is kept. The turn settled, so it is resolved and not failed.
    return _finish(
      utteranceLength: utteranceLength,
      result: _resultWrite,
      replyText: l10n.conversationWriteAwaitingConfirmation,
      status: TurnStatus.resolved,
      intent: _intentDelete,
      entity: entityName,
      operation: pending.operationKey,
      phase: _phaseConfirming,
      pending: pending,
    );
  }

  /// Issues the `DELETE` for the one record [pending] names (`FR-MC05`).
  ///
  /// Reached only from an affirmative. The identifier is bound to the path
  /// parameter the delete operation declares and there is **no body**: a delete
  /// names one record and has nothing else to say. A 2xx is the only outcome
  /// that says the record was deleted; anything else is the failure sentence
  /// with its evidence, because a failed delete must never sound like a
  /// success.
  Future<ResolverOutcome> _submitDelete({
    required int utteranceLength,
    required PendingDelete pending,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
  }) async {
    final entityName = pending.entityName;

    final operation = registry.operation(pending.operationKey);
    if (operation == null) {
      // The registry the delete was identified against no longer publishes the
      // operation. Refuse honestly and keep the target rather than addressing
      // the identifier somewhere else.
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationDeleteNoOperation(entityName),
        status: TurnStatus.failed,
        intent: _intentDelete,
        entity: entityName,
        operation: pending.operationKey,
        phase: _phaseConfirming,
        reason: 'no_delete_operation',
        pending: pending,
      );
    }

    if (operation.pathParameterNames.isEmpty) {
      // The operation the target was identified against no longer declares the
      // parameter that carries the identifier, so there is no honest way to
      // address the record. Same condition `_beginDelete` refuses, re-read here
      // because the registry may have been replaced since the read-back.
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationDeleteNoTarget(entityName),
        status: TurnStatus.failed,
        intent: _intentDelete,
        entity: entityName,
        operation: operation.key,
        phase: _phaseConfirming,
        reason: 'no_delete_parameter',
        pending: pending,
      );
    }

    // The identifier goes into the parameter the operation declares, exactly
    // the way the read path's `get` binds it. No body: a delete has nothing
    // else to say. The executor writes the one `[umlive][executor]` line for
    // this call, and that `path=` line is the only place the identifier ever
    // reaches the log.
    final bound = <String, String>{
      operation.pathParameterNames.first: pending.recordId,
    };
    final result = await executor.execute(
      operation: operation,
      pathParameters: bound,
    );
    final evidence = OperationEvidence.fromResult(result);

    // A queued delete is **not** a success and must never be reported as one:
    // the backend never received the `DELETE`, so the record is not known to be
    // gone. This is checked before `succeeded` because a queued result is
    // deliberately not a success, and reporting it as done is the one thing the
    // queue exists to prevent. The target left the conversation and now belongs
    // to the queue.
    if (result.queued) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationDeleteQueued(pending.recordId, entityName),
        status: TurnStatus.queued,
        intent: _intentDelete,
        entity: entityName,
        operation: operation.key,
        phase: _phaseConfirming,
        reason: 'queued',
        evidence: evidence,
        pending: null,
      );
    }

    if (result.succeeded) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationDeleteDone(pending.recordId, entityName),
        status: TurnStatus.resolved,
        intent: _intentDelete,
        entity: entityName,
        operation: operation.key,
        phase: _phaseConfirming,
        evidence: evidence,
        pending: null,
      );
    }

    // The call ran and the backend answered with an error, so the record is not
    // known to be gone and the queue is not a fallback: the outbox keeps a write
    // the backend never received, and this one was received. `T22` replaces this
    // sentence with one derived from the status and the `errors` keys; the
    // evidence travels with the turn either way.
    return _finish(
      utteranceLength: utteranceLength,
      result: _resultWrite,
      replyText: l10n.conversationDeleteFailed(entityName),
      status: TurnStatus.failed,
      intent: _intentDelete,
      entity: entityName,
      operation: operation.key,
      phase: _phaseConfirming,
      reason: 'write_failed',
      evidence: evidence,
      pending: null,
    );
  }

  /// Converts the complete draft and issues the create.
  ///
  /// Reached only from an affirmative (`FR-MC03`). A 2xx is the only outcome
  /// that says the record was created; a write the backend never received is
  /// queued by the executor decorator and reported as queued (`T14`); a refusal
  /// from a backend that did answer drops the draft with its evidence, because
  /// retrying a request the backend already saw would duplicate work.
  Future<ResolverOutcome> _submitWrite({
    required int utteranceLength,
    required PendingCreate pending,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
  }) async {
    final entityName = pending.entityName;
    final phase = pending.phase.name;

    if (!pending.isComplete) {
      // Unreachable by construction: confirming is entered only once nothing
      // is missing. `FR-MC02` forbids a partial body, so refuse rather than
      // build one.
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationWriteFailed(entityName),
        status: TurnStatus.failed,
        intent: _intentCreate,
        entity: entityName,
        operation: pending.operationKey,
        phase: phase,
        reason: 'incomplete_on_submit',
        pending: pending,
      );
    }

    // Every captured value was converted when it was captured, so a failure
    // here is a bug: report a failed submit, keep the draft, and say so.
    final body = <String, Object?>{};
    for (final field in pending.requiredFields) {
      final text = pending.values[field.name];
      if (text == null) continue;
      final converted = convertFieldValue(field, text);
      if (converted is! FieldValueOk) {
        return _finish(
          utteranceLength: utteranceLength,
          result: _resultWrite,
          replyText: l10n.conversationWriteFailed(entityName),
          status: TurnStatus.failed,
          intent: _intentCreate,
          entity: entityName,
          operation: pending.operationKey,
          phase: phase,
          reason: 'convert_on_submit',
          pending: pending,
        );
      }
      body[field.name] = converted.value;
    }

    final operation = registry.operation(pending.operationKey);
    if (operation == null) {
      // The registry the draft was built against no longer publishes the
      // operation. Refuse honestly and keep the draft rather than sending the
      // body somewhere else.
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationWriteNoCreateOperation(entityName),
        status: TurnStatus.failed,
        intent: _intentCreate,
        entity: entityName,
        operation: pending.operationKey,
        phase: phase,
        reason: 'no_create_operation',
        pending: pending,
      );
    }

    // The executor writes the one `[umlive][executor]` line for this call.
    final result = await executor.execute(operation: operation, body: body);
    final evidence = OperationEvidence.fromResult(result);

    // A queued create is **not** a success and must never be reported as one:
    // the backend never received the `POST`, so the record does not exist yet.
    // This is checked before `succeeded` because a queued result is deliberately
    // not a success, and reporting it as done is the one thing the queue exists
    // to prevent. The write left the conversation and now belongs to the queue.
    if (result.queued) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationCreateQueued(entityName),
        status: TurnStatus.queued,
        intent: _intentCreate,
        entity: entityName,
        operation: operation.key,
        phase: phase,
        reason: 'queued',
        evidence: evidence,
        pending: null,
      );
    }

    if (result.succeeded) {
      return _finish(
        utteranceLength: utteranceLength,
        result: _resultWrite,
        replyText: l10n.conversationWriteCreated(entityName),
        status: TurnStatus.resolved,
        intent: _intentCreate,
        entity: entityName,
        operation: operation.key,
        phase: phase,
        evidence: evidence,
        pending: null,
      );
    }

    // The backend answered and refused — a 4xx or a 5xx. Nothing was persisted
    // and the queue is deliberately not a fallback here: the outbox keeps a
    // write the backend **never received**, and this request was received, so
    // replaying it would duplicate work the backend already saw. The draft is
    // dropped and the failure is reported with its evidence.
    return _finish(
      utteranceLength: utteranceLength,
      result: _resultWrite,
      replyText: l10n.conversationWriteFailed(entityName),
      status: TurnStatus.failed,
      intent: _intentCreate,
      entity: entityName,
      operation: operation.key,
      phase: phase,
      reason: 'write_failed',
      evidence: evidence,
      pending: null,
    );
  }

  /// Every entity name the registry knows, in the sentence register
  /// (`lowerFirst`): the refusal names the vocabulary it *does* have instead
  /// of only what it missed. The names come from the registry (`FR-MC07`), so
  /// this list is exactly as long as the backend's own description.
  static List<String> _knownEntityNames(ApiRegistry registry) =>
      registry.entities.map((entity) => lowerFirst(entity.name)).toList();

  /// The best window of [tokens] that names [entity], or null.
  ///
  /// Matching is accent- and case-insensitive and compares *whole folded
  /// tokens only*, which is what keeps `clientela` from matching `cliente`:
  /// the windows are token ranges, never substrings of a token. A window is
  /// joined with no separator, so an entity whose recovered name has no space
  /// (`ItemPedido`) is still named by the spoken two words "item pedido".
  ///
  /// A window is accepted when it equals the folded name, that name with the
  /// singular `s`/`es` plural, or — for a name ending in `z` — its `ces`
  /// plural. Nothing else is a match.
  static _EntityMatch? _bestMatch(EntityModel entity, List<String> tokens) {
    final fold = foldText(entity.name);
    if (fold.isEmpty) return null;

    // A joined window only ever grows, so once it is longer than any accepted
    // form it can be, no longer window can match either.
    final limit = fold.length + 2;
    _EntityMatch? best;

    for (var start = 0; start < tokens.length; start++) {
      final buffer = StringBuffer();
      for (var end = start; end < tokens.length; end++) {
        buffer.write(tokens[end]);
        final joined = buffer.toString();
        if (joined.length > limit) break;
        if (!_accepts(fold, joined)) continue;
        final candidate = _EntityMatch(
          entity: entity,
          tokenCount: end - start + 1,
          foldLength: fold.length,
          windowStart: start,
          windowEnd: end + 1,
        );
        if (best == null || _byScore(candidate, best) < 0) best = candidate;
      }
    }
    return best;
  }

  /// Whether [joined] is [fold] or one of its plural forms.
  static bool _accepts(String fold, String joined) {
    if (joined == fold) return true;
    if (joined == '${fold}s') return true;
    if (joined == '${fold}es') return true;
    if (fold.endsWith('z') &&
        joined == '${fold.substring(0, fold.length - 1)}ces') {
      return true;
    }
    return false;
  }

  /// More matched tokens wins; on equal tokens, the longer entity name wins.
  ///
  /// The token count separates two entities named by a different number of
  /// spoken words. The second term covers the remaining case, where both names
  /// accept the *same* tokens — `Cliente` and `Clientes` both accept the token
  /// `clientes` — and the longer, more specific name is the one that was said.
  ///
  /// Windows that do not overlap are never compared by this ordering, because
  /// those are two mentions of two different entities and `resolve` treats
  /// them as an ambiguity rather than a ranking.
  static int _byScore(_EntityMatch a, _EntityMatch b) {
    final byTokens = b.tokenCount.compareTo(a.tokenCount);
    if (byTokens != 0) return byTokens;
    return b.foldLength.compareTo(a.foldLength);
  }

  /// What the utterance asks for, once the entity is known.
  static _IntentPlan _classifyIntent(
    EntityModel entity,
    List<String> tokens,
    _EntityMatch match,
  ) {
    if (tokens.any(countTriggers.contains)) {
      return const _IntentPlan(_Intent.count);
    }

    final numeric = tokens.where(_isNumeric).toList();
    if (numeric.isNotEmpty) {
      // A single record was named. It is a `get` only if the backend publishes
      // a way to read one; otherwise it is not understood, because answering
      // with the whole collection would silently drop the filter the operator
      // asked for.
      if (entity.roleKeys.containsKey(EntityRole.get)) {
        return _IntentPlan(_Intent.get, numeric.first);
      }
      return const _IntentPlan(_Intent.unknown);
    }

    if (tokens.any(readListTriggers.contains)) {
      return const _IntentPlan(_Intent.list);
    }

    // Nothing left that asks for anything: every token is either part of the
    // entity's own name or a word that carries no request. An utterance that
    // only names an entity is a request to read it.
    for (var index = 0; index < tokens.length; index++) {
      final insideName = index >= match.windowStart && index < match.windowEnd;
      if (insideName) continue;
      if (utteranceFillers.contains(tokens[index])) continue;
      return const _IntentPlan(_Intent.unknown);
    }
    return const _IntentPlan(_Intent.list);
  }

  /// Tokens are already folded to `[a-z0-9]`, so "all digits" is all this
  /// needs.
  static bool _isNumeric(String token) => _digits.hasMatch(token);

  static final RegExp _digits = RegExp(r'^[0-9]+$');
}

/// What one utterance asks the resolver to do.
enum _Intent {
  /// How many records there are.
  count,

  /// The collection.
  list,

  /// One record, named by a numeric token that its operation takes as a path
  /// parameter.
  get,

  /// The entity is known and the request is not.
  unknown,
}

/// An intent plus the value it carries, if any.
class _IntentPlan {
  const _IntentPlan(this.intent, [this.recordId]);

  final _Intent intent;

  /// The numeric token that named a single record, for `_Intent.get` only.
  final String? recordId;
}

/// One entity's best-fitting window of the utterance.
class _EntityMatch {
  const _EntityMatch({
    required this.entity,
    required this.tokenCount,
    required this.foldLength,
    required this.windowStart,
    required this.windowEnd,
  });

  final EntityModel entity;

  /// How many utterance tokens the window covers.
  final int tokenCount;

  /// Length of the entity's folded name, the tie-breaker when two entities
  /// match the same number of tokens.
  final int foldLength;

  /// Token indexes of the window, `[windowStart, windowEnd)`. The resolver
  /// needs them to know which tokens were the entity's own name and which
  /// were the operator's words.
  final int windowStart;
  final int windowEnd;

  /// Whether this match and [other] cover any token in common, and so are two
  /// readings of one mention rather than two mentions.
  bool overlaps(_EntityMatch other) =>
      windowStart < other.windowEnd && other.windowStart < windowEnd;
}
