/// Turns a failed operation into the sentence the operator reads (`T22`).
///
/// **One place, two entry points, and one rule (`FR-ME05`).** The generated
/// backend's `ApiExceptionHandler` answers a constraint violation with a body
/// carrying an `errors` map whose **keys are field names**. Its *values* are
/// Bean Validation message text, which the JVM localises from its own locale:
/// the same violation reads differently on a backend started with another
/// `-Duser.language`, so the values are **not a stable contract** and no
/// sentence here is ever built from one. The keys are the stable half of that
/// map, and they are the only half this file reads.
///
/// The consequence is the point of the requirement: a sentence names the fields
/// the backend rejected, the record it could not find, or the conflict with the
/// data that already exists — never a message the backend happened to be
/// configured to produce that day.
///
/// **This is the only mapping of a failure to copy in the app.** The live path
/// (`deterministic_resolver.dart`) and the queue screen (`queue_screen.dart`)
/// both come here, so one fact cannot be told two ways depending on which
/// surface is in front of the operator. Before this file existed it was: the
/// resolver answered every non-2xx call with one of three generic sentences and
/// left the status out of the sentence entirely, while the queue screen named
/// the status in a sentence of its own — the same `404` described twice, in two
/// different vocabularies, by the same app.
library;

import '../l10n/app_localizations.dart';
import '../presentation/discovered_scope.dart';
import 'operation_executor.dart';

/// The sentence for a failed operation, from its outcome and the entity the
/// operator was talking about.
///
/// [entity] is the entity in the sentence register the caller already resolves
/// for its own copy (`lowerFirst` of the registry's own word), and it is
/// required: every caller of this entry point has one, because a live call was
/// made through an operation the registry published at that moment.
///
/// The branches are ordered, and the order is part of the design:
///
/// 1. **The field keys of `errors`, when the body carried them.** They come
///    first because they are the most specific fact any answer can carry, and
///    because `FR-ME05` names them as the contract: a status says the request
///    was refused, while the keys say *which fields* were. **Only the keys are
///    read.** The values beside them are JVM-locale message text, so a sentence
///    built from one would change with the backend's locale and with nothing
///    this app did. The keys are joined with the app's own list connectors
///    (`joinEntityNames`, the helper the entity lists already use), so a list of
///    fields reads the way every other list in the app reads.
/// 2. **`404`.** The record was not found. Only reached when the body carried
///    no `errors` map — branch 1 takes that case — so the missing record is the
///    one fact there is to name.
/// 3. **`409`.** The operation conflicts with the data that already exists. It
///    sits after `404` because it is the third status the generated handler
///    maps, and above the generic refusals below because it is a nameable cause:
///    the request was well formed and the state of the data is what refused it.
/// 4. **Any other `4xx`.** The backend refused, with the code. Nothing more
///    specific is left to say, and the code is what the operator can report
///    back; an invented cause would be worse than a number.
/// 5. **Any `5xx`.** The backend's own error, with the code. It is a separate
///    branch because it means something different to whoever reads the
///    sentence: a `4xx` is the request being refused, a `5xx` is the backend
///    failing on its own.
/// 6. **A timeout or an unreachable network.** The backend could not be
///    reached. Neither of those ever carries a status, which is why this branch
///    can sit below the status ones and still be reachable.
/// 7. **No backend configured.** There is nothing callable yet — a state of the
///    app and not of the network, the same distinction the Connect screen's own
///    copy makes.
/// 8. **Anything else.** The generic refusal when a status exists at all (a
///    `1xx` or a `3xx` the client did not resolve, or a failure this build does
///    not classify), and the unreachable sentence when there is no status: to
///    the operator, a call that produced no answer and a backend that gave none
///    are the same fact, and neither may be dressed up as a refusal the backend
///    never sent.
String errorSentence(
  AppLocalizations l10n, {
  required String entity,
  required OperationResult result,
}) {
  // 1. The stable half of the generated handler's contract, and the most
  //    specific thing any answer here can carry (`FR-ME05`).
  final fieldErrors = result.fieldErrors;
  if (fieldErrors != null && fieldErrors.isNotEmpty) {
    return l10n.errorFieldsRejected(
      joinEntityNames(l10n, fieldErrors.keys.toList()),
    );
  }

  final status = result.statusCode;

  // 2. A record that is not there. The backend answered, so this is not a
  //    reachability problem, and no field was named, so it is not a rejection
  //    of the request's shape either.
  if (status == 404) return _notFound(l10n, entity);

  // 3. The request was well formed and the data refused it. A different cause
  //    than either neighbour, and one the operator can act on, so it gets its
  //    own sentence rather than a status number.
  if (status == 409) return l10n.errorConflict;

  // 4. A refusal with no more specific reading: the code is the honest fact.
  if (status != null && status >= 400 && status < 500) {
    return l10n.errorClient(status);
  }

  // 5. The backend failed on its own, which is a different sentence from the
  //    request being refused.
  if (status != null && status >= 500) return l10n.errorServer(status);

  // 6. The two failures of reaching the backend at all. Neither carries a
  //    status — that is what makes it this branch and not one of the above.
  if (result.failure == OperationFailureKind.timeout ||
      result.failure == OperationFailureKind.networkUnreachable) {
    return _noAnswer(l10n, entity);
  }

  // 7. The app's own state: nothing was ever configured to call.
  if (result.failure == OperationFailureKind.noBackendConfigured) {
    return l10n.errorNoBackend;
  }

  // 8. Whatever is left. A status this build does not classify still gets said
  //    as a refusal with its code, because the backend did answer; a failure
  //    with no status at all gets the unreachable sentence, because there is no
  //    answer to describe and no refusal to claim.
  if (status != null) return l10n.errorClient(status);
  return _noAnswer(l10n, entity);
}

/// The sentence for a queued item that failed on replay, from the stable code
/// the drain stored and the entity the queue screen already resolves for its
/// own label.
///
/// **The row is the only thing that survives.** A failed item is read back
/// months later, when the sentence is the whole of what the operator has, so
/// the drain (`T16`) persists a **code** and never a sentence, and this entry
/// point is what turns that code back into copy. The codes are `no_answer` for
/// a call that got no answer at all, `rejected:<status>` for a backend that
/// answered outside 2xx, and `operation_not_in_registry` when the current
/// registry no longer publishes the item's operation.
///
/// [entity] is nullable here and that is not a convenience: an item whose
/// operation the registry no longer publishes belongs to no entity, so there is
/// no domain word to name, and the entity-free forms exist for exactly that
/// case. They are used only when it is null — a named entity is always better
/// copy than a generic sentence.
///
/// The mapping, and why each code takes the branch it does:
///
/// - `no_answer` takes the unreachable sentence, the same one a live timeout or
///   transport failure gets.
/// - `rejected:404`, `rejected:409` and any other status take the same status
///   branches `errorSentence` uses for a status: the not-found, the conflict,
///   the backend's own error for a `5xx` and the refusal-with-code sentence.
///   The status was stored beside the code precisely so the screen could say
///   this much, and a `5xx` must read the same on both paths.
/// - The bare `rejected` of a row written before the status was persisted
///   beside the code takes a sentence that does **not** claim a status. The
///   backend did answer — that is what the code says — and the row lost which
///   code it answered with, so the sentence says the refusal and stops.
/// - `operation_not_in_registry` takes its own sentence: the operation cannot
///   be replayed at all, which is a different fact from a replay that failed.
/// - A code this build cannot parse takes the legacy refusal sentence. The code
///   is the drain's own contract with its history, so an unrecognised one means
///   a build wrote something this one does not know; claiming a specific cause
///   for it would be inventing evidence, and the least specific refusal is the
///   most that can be said.
///
/// A `null` [storedReason] keeps the reading it had before this mapper existed:
/// the no-answer sentence. A row the drain marked failed always carries a code
/// (`OutboxRepository.markFailed` takes one), so null means the row arrived by
/// some other road, and "no answer" is what the screen said about it before.
String replayErrorSentence(
  AppLocalizations l10n, {
  required String? entity,
  required String? storedReason,
}) {
  if (storedReason == null) return _noAnswer(l10n, entity);

  final separator = storedReason.indexOf(':');
  final kind = separator == -1
      ? storedReason
      : storedReason.substring(0, separator);
  final storedStatus = separator == -1
      ? null
      : int.tryParse(storedReason.substring(separator + 1));

  switch (kind) {
    case 'no_answer':
      return _noAnswer(l10n, entity);
    case 'operation_not_in_registry':
      return l10n.queueFailedOrphan;
    case 'rejected':
      if (storedStatus == 404) return _notFound(l10n, entity);
      if (storedStatus == 409) return l10n.errorConflict;
      if (storedStatus != null && storedStatus >= 500) {
        return l10n.errorServer(storedStatus);
      }
      if (storedStatus != null) return l10n.errorClient(storedStatus);
      return l10n.queueFailedRejected;
  }
  return l10n.queueFailedRejected;
}

/// The not-found sentence, in the entity-free form when there is no entity to
/// name. The generic form exists for the queue screen only: an item whose
/// operation left the registry still carries the stored status of the refusal
/// it got while it was in it, and that refusal is still true.
String _notFound(AppLocalizations l10n, String? entity) => entity == null
    ? l10n.errorNotFoundGeneric
    : l10n.errorNotFound(entity);

/// The unreachable sentence, the same way: an entity-free form for the item no
/// entity can be named for, and the named form everywhere a name exists.
String _noAnswer(AppLocalizations l10n, String? entity) => entity == null
    ? l10n.errorNoAnswerGeneric
    : l10n.errorNoAnswer(entity);
