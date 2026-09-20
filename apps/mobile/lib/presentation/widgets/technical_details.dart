import 'package:flutter/material.dart';

import '../../conversation/turn.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';

/// The machinery behind one assistant turn, as a muted block under it (`T23`,
/// `FR-ME06`).
///
/// **This is the one surface in the app where the machinery is allowed on
/// screen**, and it is only ever drawn when the operator asked for it: the mode
/// is on and the turn carries [OperationEvidence]. It is the shortest possible
/// answer to *"how does discovery work?"* — the verb, the path the app actually
/// called, the status, the latency, and the version of the document the
/// operation came from — which is why the PRD treats it as the live defence of
/// the model-driven claim rather than as polish (UX spec Pass 6, *"Evaluator
/// asks how discovery works and nothing shows it"*).
///
/// The rows are the same label/value shape and the same two text roles the
/// record cards use, so the block reads as part of the same family. What makes
/// it *muted* is everything around them: it sits outside the assistant bubble,
/// with a hairline border but no fill, no accent colour and no glow — machinery
/// under an answer, never beside it.
///
/// **It shows no secrets, and that is a rule and not an incomplete rendering:**
/// no bearer token, no request body, no response body. The five facts here are
/// the operation's *shape*; the values sent and received are the operator's own
/// data and belong on a card (`FR-ME03`), which is also why nothing from
/// `decodedBody` is reachable from this widget.
///
/// Two absences are stated in words rather than shown as blanks, because a
/// blank reads as a fact and a zero reads as a fast success:
///
/// - a turn whose call never reached the backend — a queued write — has no
///   status, and *Estado* says **No enviado**;
/// - it has no latency either, and *Latencia* says **Sin medir**. The evidence
///   does carry the duration of the failed attempt, and that number is real,
///   but it is not a latency: a thirty-second timeout presented under this
///   label would read as a backend that answered slowly. The row therefore
///   follows the status — no answer, nothing measured — and never prints a
///   zero.
///
/// The last line names the document version, and it is the **document's own**
/// `openapi` field, never a constant the app believes: that is what turns
/// *"the app discovers operations"* into something the Evaluator can check per
/// turn. When the document declared no version at all there is no provenance
/// sentence to write, and none is invented — the four rows are shown and the
/// sentence is omitted.
class TechnicalDetails extends StatelessWidget {
  const TechnicalDetails({super.key, required this.evidence});

  /// What the executor returned for the call this turn made, plus the version
  /// of the document the operation was discovered from.
  final OperationEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final status = evidence.statusCode;
    // "Latency" means how long **the answered call** took. A call that got no
    // answer has none to report, so the row follows the status: see the class
    // comment for the queued write this exists to keep honest.
    final latency = status == null ? null : evidence.latencyMs;
    final version = evidence.openapiVersion;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _TechnicalRow(
            label: l10n.technicalMethodLabel,
            value: evidence.method,
          ),
          const SizedBox(height: AppSpacing.xs),
          _TechnicalRow(
            label: l10n.technicalPathLabel,
            // The path **after** substitution, never the template: the template
            // is what the app knows, the resolved path is what it did.
            value: evidence.resolvedPath,
          ),
          const SizedBox(height: AppSpacing.xs),
          _TechnicalRow(
            label: l10n.technicalStatusLabel,
            value: status == null
                ? l10n.technicalStatusNotSent
                : status.toString(),
          ),
          const SizedBox(height: AppSpacing.xs),
          _TechnicalRow(
            label: l10n.technicalLatencyLabel,
            value: latency == null
                ? l10n.technicalLatencyUnknown
                : l10n.technicalLatencyValue(latency),
          ),
          if (version != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.technicalDiscovered(version),
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// One label/value row of the technical block.
///
/// The same shape and the same two text roles as a record card's row
/// (`record_cards.dart`): a muted label, and a value that wraps rather than
/// truncates, so the largest font scale grows the block instead of clipping the
/// path (`FR-MG06`).
class _TechnicalRow extends StatelessWidget {
  const _TechnicalRow({required this.label, required this.value});

  /// The row's name, from the ARB — *Método*, *Ruta resuelta*, *Estado*,
  /// *Latencia*.
  final String label;

  /// The value, already rendered: a verb, a resolved path, a status code and
  /// its not-sent copy, or a latency and its not-measured copy.
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}
