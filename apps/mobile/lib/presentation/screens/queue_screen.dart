import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../conversation/conversation_controller.dart';
import '../../data/outbox_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../openapi/registry.dart';
import '../../theme/tokens.dart';
import '../discovered_scope.dart';
import '../widgets/app_background.dart';

/// Queue (`FR-MG01`, `FR-MD07`, `FR-MD08`): the promises the app made and has
/// not kept yet.
///
/// `T1` rendered the empty state only. `T18` renders the real queue: the
/// outstanding items in issue order, each one saying in domain language what it
/// will do, carrying its status, and offering exactly the two decisions
/// `FR-MD07` and `FR-MD08` allow — discard an item, or retry a failed one.
///
/// **This screen never touches the database.** It reads
/// [ConversationController.queueItems] and asks the controller to cancel or
/// retry, because the controller owns the queue's state (`T18`): the app-bar
/// badge and this list are projections of the same read and cannot disagree.
///
/// **Nothing here is a developer's view of the queue.** No operation key, no
/// resolved path, no raw JSON and no raw stored code: what an item will do is
/// said in the operator's words, and why it failed is said in domain language.
/// The method, the path and the status belong to `T23`'s technical mode.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  /// The queue is re-read once, when the screen appears, so it shows what the
  /// database holds now rather than what the app-bar badge last saw.
  bool _requestedRefresh = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requestedRefresh) return;
    _requestedRefresh = true;
    final conversation = AppScope.of(context).conversation;
    // Post-frame, because `refreshQueue` notifies and a notification raised
    // while this widget is building would rebuild the tree mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(conversation.refreshQueue());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final services = AppScope.of(context);
    final conversation = services.conversation;
    final connection = services.connection;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.queueTitle)),
        body: SafeArea(
          child: ListenableBuilder(
            // The registry is what turns an item's operation key into a domain
            // word, so one that arrives after the queue redraws the list; the
            // conversation is what changes the items themselves.
            listenable: Listenable.merge(<Listenable>[
              conversation,
              connection,
            ]),
            builder: (context, _) {
              final items = conversation.queueItems;
              // Pass 5, *Empty*: nothing at all, and no entry point either.
              // An empty queue costs zero attention.
              if (items.isEmpty) return const _QueueEmpty();
              final registry = connection.apiRegistry;
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.xl,
                ),
                itemCount: items.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final item = items[index];
                  // An item a drain has taken is already being sent: there is
                  // nothing to take back and nothing to retry, so its swipe is
                  // not offered at all (UX spec Pass 5, *Draining*).
                  final inFlight = item.status == OutboxStatus.inFlight;
                  return Dismissible(
                    key: ValueKey<int>(item.id),
                    direction: inFlight
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    background: _QueueDiscardBackground(l10n: l10n),
                    // The swipe asks the same confirmation the explicit control
                    // does; nothing about this queue is destroyed by a gesture
                    // alone.
                    confirmDismiss: (_) =>
                        _confirmAndCancel(context, conversation, item.id),
                    child: _QueueItemCard(
                      item: item,
                      entityName: _entityNameFor(registry, item.operationKey),
                      recordId: _recordIdFor(registry, item),
                      onDiscard: () => unawaited(
                        _confirmAndCancel(context, conversation, item.id),
                      ),
                      onRetry: () =>
                          unawaited(conversation.retryQueued(item.id)),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// Asks for confirmation and cancels only when it is given.
  ///
  /// A destructive action on a list is confirmed exactly as a destructive voice
  /// command is (`FR-MD07`): the two controls ask, and the answer is what
  /// decides. Returning the answer lets one helper serve both affordances — the
  /// swipe's `confirmDismiss` and the explicit control inside the card.
  Future<bool> _confirmAndCancel(
    BuildContext context,
    ConversationController conversation,
    int id,
  ) async {
    final confirmed = await _confirmDiscard(context);
    if (!confirmed) return false;
    await conversation.cancelQueued(id);
    return true;
  }

  /// The confirmation itself: title, what discarding means, and two explicit
  /// choices of unequal weight, the destructive one never pre-selected
  /// (UX spec Pass 3).
  Future<bool> _confirmDiscard(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.queueCancelConfirmTitle),
        content: Text(l10n.queueCancelConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.queueKeepAction),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(l10n.queueDiscard),
          ),
        ],
      ),
    );
    // Dismissing the dialog by tapping outside it is not an answer, and the
    // safe reading of no answer is to keep the promise.
    return answer ?? false;
  }
}

/// One queued item: what it will do, where it is, why it failed, and the
/// decisions available on it.
class _QueueItemCard extends StatelessWidget {
  const _QueueItemCard({
    required this.item,
    required this.entityName,
    required this.recordId,
    required this.onDiscard,
    required this.onRetry,
  });

  final OutboxItem item;

  /// The entity of the registry whose `operationKeys` carries the item's
  /// operation, in sentence register, or null when none does.
  final String? entityName;

  /// The identifier a delete will act on, already recovered from the item's
  /// bound path parameters.
  final String recordId;

  final VoidCallback onDiscard;

  /// Retry is rendered on a failed item and nowhere else (`FR-MD08`, UX spec
  /// Pass 3): a pending item has not failed yet, so there is nothing to retry.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final failed = item.status == OutboxStatus.failed;
    final inFlight = item.status == OutboxStatus.inFlight;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(_intent(l10n), style: textTheme.titleMedium),
              ),
              const SizedBox(width: AppSpacing.sm),
              _QueueStatusChip(status: item.status),
            ],
          ),
          if (failed) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            // The reason, in domain language. No second `error_outline` mark:
            // the chip above already carries the state as a word and an icon,
            // and repeating the icon here would make one fact look like two.
            Text(
              _failureReason(l10n, item.lastError),
              style: textTheme.bodySmall?.copyWith(color: AppColors.danger),
            ),
          ],
          if (item.attempts > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(l10n.queueAttempts(item.attempts), style: textTheme.bodySmall),
          ],
          // An in-flight item is already being sent, so neither affordance is
          // offered: cancelling could not stop it and retrying would duplicate
          // it. The card still shows it, marked `Enviando…`, because it is
          // work the app still owes (UX spec Pass 5, *Draining*).
          if (!inFlight) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (failed)
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.queueRetryAction),
                  ),
                // A swipe alone is not discoverable and is impossible for some
                // operators, so the same decision always has a visible control
                // (UX spec Pass 3).
                TextButton.icon(
                  onPressed: onDiscard,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.queueDiscardAction),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// What the item will do, in domain language (`FR-MD07`).
  ///
  /// An operation the current registry no longer publishes cannot be named: it
  /// belongs to no entity, so the honest generic sentence is used instead of a
  /// word nothing can supply.
  String _intent(AppLocalizations l10n) {
    final entity = entityName;
    if (entity == null) return l10n.queueItemUnknown;
    return item.kind == OutboxKind.create
        ? l10n.queueItemCreate(entity)
        : l10n.queueItemDelete(recordId, entity);
  }
}

/// The item's state, as a word **and** an icon.
///
/// `FR-MG04` and the UX spec forbid carrying a state in colour alone, and the
/// three queue states differ in copy — *En cola*, *Enviando…*, *Falló* — so
/// they stay distinguishable to an operator who cannot see the chip's tint.
class _QueueStatusChip extends StatelessWidget {
  const _QueueStatusChip({required this.status});

  final OutboxStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final (String label, IconData icon, Color colour) = switch (status) {
      OutboxStatus.pending => (
        l10n.queueStatusPending,
        Icons.schedule_outlined,
        AppColors.textMuted,
      ),
      OutboxStatus.inFlight => (
        l10n.queueStatusInFlight,
        Icons.send_outlined,
        AppColors.accent,
      ),
      OutboxStatus.failed => (
        l10n.queueStatusFailed,
        Icons.error_outline,
        AppColors.danger,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: AppRadii.pillAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: AppTextSizes.chip, color: colour),
          const SizedBox(width: AppSpacing.sm),
          Text(label, style: textTheme.labelLarge?.copyWith(color: colour)),
        ],
      ),
    );
  }
}

/// The destructive action a swipe reveals (`FR-MD07`).
///
/// It is a reveal, not a decision: the confirmation behind it is what actually
/// discards the item, which is why the title and the icon travel together —
/// the same mark, one meaning.
class _QueueDiscardBackground extends StatelessWidget {
  const _QueueDiscardBackground({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.danger),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.delete_outline, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Text(
            l10n.queueDiscard,
            style: textTheme.labelLarge?.copyWith(color: AppColors.danger),
          ),
        ],
      ),
    );
  }
}

/// The empty queue (UX spec Pass 5, *Empty*): the statement that there is
/// nothing outstanding, and nothing else — no controls and no headers, because
/// an empty queue must cost zero attention.
class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Icon plus text, never one without the other.
          const Icon(
            Icons.inbox_outlined,
            size: AppSizes.minTouchTarget,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              l10n.queueEmpty,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The entity whose `operationKeys` carries [operationKey], in sentence
/// register, or null when none does.
///
/// The same lookup `OutboxDrainer` performs: the registry is the only place a
/// domain word comes from (`FR-MC07`), and the screen does it again here rather
/// than holding a second copy of it anywhere.
String? _entityNameFor(ApiRegistry? registry, String operationKey) {
  if (registry == null) return null;
  for (final entity in registry.entities) {
    if (entity.operationKeys.contains(operationKey)) {
      return lowerFirst(entity.name);
    }
  }
  return null;
}

/// The identifier a delete will act on, recovered from the values bound to the
/// operation's **declared** path parameters.
///
/// `T13b` binds the record the operator named to the operation's first path
/// parameter, so that is where the queue finds it again — by the name the
/// document declares, never by a path assembled here (`FR-MA03`).
String _recordIdFor(ApiRegistry? registry, OutboxItem item) {
  final operation = registry?.operation(item.operationKey);
  final names = operation?.pathParameterNames ?? const <String>[];
  if (names.isNotEmpty) {
    final bound = item.pathParameters[names.first];
    if (bound != null) return bound;
  }
  final values = item.pathParameters.values;
  return values.isEmpty ? '' : values.first;
}

/// The reason a failed item carries, in domain language.
///
/// It is derived from the **stable code** in `outbox.last_error` and never from
/// the stored string itself. The four codes it knows are the schema's contract
/// with the drain (`T16`) **and with its history**, and each one has to be
/// named for what it actually says: `no_answer` when the backend never
/// answered, `rejected:<status>` when it answered outside 2xx, the bare
/// `rejected` a row written before the status was persisted beside the code
/// carries — a refusal, and deliberately not a *no answer*, because the
/// backend did answer and the row only lost which code it answered with — and
/// `operation_not_in_registry` when the current registry no longer publishes
/// the operation.
///
/// The row is the only thing that survives, so this mapping is what lets the
/// screen name the reason months later — and a code this build cannot parse
/// gets the least specific sentence rather than an invented status or an
/// invented orphaning.
String _failureReason(AppLocalizations l10n, String? code) {
  if (code == null) return l10n.queueFailedNoAnswer;
  final separator = code.indexOf(':');
  final kind = separator == -1 ? code : code.substring(0, separator);
  final value = separator == -1 ? null : code.substring(separator + 1);
  switch (kind) {
    case 'no_answer':
      return l10n.queueFailedNoAnswer;
    case 'operation_not_in_registry':
      return l10n.queueFailedOrphan;
    case 'rejected':
      final status = value == null ? null : int.tryParse(value);
      if (status != null) return l10n.queueFailedStatus(status);
      // The status is not in the row, so it cannot be reported: the sentence
      // says the refusal without inventing the code it came with.
      return l10n.queueFailedRejected;
  }
  return l10n.queueFailedNoAnswer;
}
