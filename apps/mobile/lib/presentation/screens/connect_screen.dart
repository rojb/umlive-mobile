import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../net/backend_address.dart';
import '../../net/reachability.dart';
import '../../openapi/registry.dart';
import '../../openapi/registry_diff.dart';
import '../../theme/tokens.dart';
import '../connection_controller.dart';
import '../discovered_scope.dart';
import '../routes.dart';
import '../widgets/app_background.dart';
import '../widgets/reachability_indicator.dart';

/// Connect (`FR-MG01`, `FR-MA01`, `FR-MA05`).
///
/// One address, one optional token behind an advanced affordance, one action.
/// The screen owns the text fields and nothing else: normalization, storage and
/// the probe all live in [ConnectionController].
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();

  bool _advancedOpen = false;
  bool _prefilled = false;

  /// True while the user is re-entering an address after a successful connect,
  /// so the Success state is never a dead end.
  bool _editingAddress = false;

  /// The typed text, normalized as it changes, so the cleartext warning appears
  /// before the user commits to the address.
  BackendAddress? _typedAddress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final stored = AppScope.of(context).connection.address;
    if (stored != null) {
      _addressController.text = stored.display;
      _typedAddress = stored;
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final connection = AppScope.of(context).connection;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.connectTitle)),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: connection,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _content(context, l10n, connection),
            ),
          ),
        ),
      ),
    );
  }

  /// UX spec, Pass 5 — the states of the screen, in priority order.
  ///
  /// A backend that answered but produced no description gets the *Partial*
  /// state, not the form: the address is right, so asking for it again would
  /// hide the cause the operator has to read (`FR-MA06`).
  Widget _content(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    if (connection.isProbing) {
      return _buildLoading(context, l10n, connection);
    }
    if (!_editingAddress && connection.discoveryFailed) {
      return _buildPartial(context, l10n, connection);
    }
    final registry = connection.apiRegistry;
    if (!_editingAddress && registry != null && connection.canProceed) {
      return _buildSuccess(context, l10n, connection, registry);
    }
    return _buildForm(context, l10n, connection);
  }

  /// UX spec, Pass 5 — Connection *Partial*: the backend was reached and it
  /// publishes no API description (`FR-MA06`).
  ///
  /// The cause is named by its own sentence, never by a status code, and the
  /// state offers exactly the two actions the UX spec gives it: retry the same
  /// address, or change it. No entity, route or operation appears here, because
  /// nothing was derived: guessing is the one thing `FR-MA06` forbids.
  Widget _buildPartial(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final view = ReachabilityView.of(context, connection);
    final registry = connection.apiRegistry;
    final rememberdEntities = registry != null && !registry.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(view.icon, color: view.color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(view.label, style: textTheme.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(view.sentence, style: textTheme.bodyMedium),
        if (rememberdEntities) ...[
          const SizedBox(height: AppSpacing.md),
          // FR-MA04: the app still works from what it learned last time. Saying
          // so is not showing remembered data as live — the note says which it
          // is — and the conversation screen keeps working from that registry.
          Text(
            l10n.connectSuccessCachedNote,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: connection.probeStored,
          child: Text(l10n.connectRetry),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: () => setState(() => _editingAddress = true),
          child: Text(l10n.connectChangeAddress),
        ),
      ],
    );
  }

  /// UX spec, Pass 5 — Connection *Success*: the entity names the app derived
  /// and how many operations it can call. This is where discovery becomes
  /// visible to the operator (`FR-MA03`, Pass 6).
  ///
  /// Every name here comes from the registry, so nothing is shown as discovered
  /// that the document did not declare. When the registry is the cached one, it
  /// says so; when it declares no operation, it says that too and offers no way
  /// into a conversation that could only fail.
  Widget _buildSuccess(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
    ApiRegistry registry,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final names = registry.entities.map((entity) => entity.name).toList();
    final change = connection.registryChange;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle_outline, color: AppColors.success),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                l10n.connectSuccessHeadline,
                style: textTheme.titleMedium,
              ),
            ),
          ],
        ),
        if (connection.registryFromCache) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.connectSuccessCachedNote,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        if (registry.operations.isEmpty)
          Text(
            l10n.connectSuccessNoOperations,
            style: textTheme.bodyMedium,
          )
        else ...[
          Text(
            l10n.connectSuccessEntities(joinEntityNames(l10n, names)),
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.connectSuccessOperations(registry.operations.length),
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
          ),
        ],
        // FR-MA07: hidden until a change happens, then Primary.
        if (change != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _RegistryChangeReport(diff: change),
        ],
        const SizedBox(height: AppSpacing.xl),
        // An API with no operations cannot answer anything: the conversation is
        // not offered, so the app never presents a surface that can only fail.
        if (registry.operations.isNotEmpty)
          FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).pushNamedAndRemoveUntil(AppRoutes.assistant, (route) => false),
            child: Text(l10n.connectStart),
          ),
        if (registry.operations.isNotEmpty) const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: () => setState(() => _editingAddress = true),
          child: Text(l10n.connectChangeAddress),
        ),
        const SizedBox(height: AppSpacing.xl),
        const ReachabilityIndicator(),
      ],
    );
  }

  /// UX spec, Pass 5 — Connection *Loading*: the address is echoed, progress is
  /// shown, and cancel is always available.
  Widget _buildLoading(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.connectLoadingEcho(connection.address?.display ?? ''),
          style: textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Text(l10n.connectProgress, style: textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton(
          onPressed: connection.cancel,
          child: Text(l10n.connectCancel),
        ),
      ],
    );
  }

  Widget _buildForm(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final problem = connection.addressProblem;
    final cleartext =
        (_typedAddress?.isCleartext ?? false) || connection.showsCleartextWarning;
    // The same form serves two arrivals, and only one of them is a cold start:
    // this screen is also reached from Settings and from «Cambiar dirección»,
    // with the stored address already in the field. Announcing "todavía no hay
    // ningún backend conectado" there contradicted both that field and the
    // «Conectado» card below it, on the same screen.
    final changing = connection.hasStoredProfile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // UX spec, Pass 4 — first launch: an address and nothing else.
        Text(
          changing ? l10n.connectExplanationChange : l10n.connectExplanation,
          style: textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          changing ? l10n.connectHelpChange : l10n.connectHelp,
          style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(l10n.connectFieldLabel, style: textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _addressController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onChanged: _onAddressChanged,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(hintText: l10n.connectFieldHint),
        ),
        if (problem != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ProblemNote(text: _problemSentence(l10n, problem)),
        ],
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
            icon: const Icon(Icons.key_outlined),
            label: Text(
              _advancedOpen
                  ? l10n.connectAdvancedHide
                  : l10n.connectAdvancedReveal,
            ),
          ),
        ),
        if (_advancedOpen) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(l10n.connectTokenLabel, style: textTheme.labelLarge),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _tokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: l10n.connectTokenHint),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.connectTokenHelp,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        if (cleartext) ...[
          const SizedBox(height: AppSpacing.md),
          _CleartextWarning(
            text: l10n.connectCleartextWarning(
              _typedAddress?.base.host ?? connection.address?.base.host ?? '',
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.connectSubmit),
        ),
        if (connection.reachability != ReachabilityState.neverConnected) ...[
          const SizedBox(height: AppSpacing.xl),
          const ReachabilityIndicator(),
        ],
      ],
    );
  }

  void _onAddressChanged(String value) {
    AppScope.of(context).connection.clearAddressProblem();
    final outcome = BackendAddressParser.parse(value);
    setState(() {
      _typedAddress = outcome is AddressAccepted ? outcome.address : null;
    });
  }

  Future<void> _submit() async {
    final connection = AppScope.of(context).connection;
    final usable = await connection.connect(
      rawAddress: _addressController.text,
      token: _tokenController.text,
    );
    if (!mounted) return;
    // The form only comes back when the address itself is unusable, or when
    // nothing could be reached. A backend that answered has its own state to
    // show: Success, or the explicit discovery failure of `FR-MA06`.
    setState(
      () => _editingAddress = !usable && !connection.discoveryFailed,
    );
  }

  static String _problemSentence(AppLocalizations l10n, AddressProblem problem) {
    switch (problem) {
      case AddressProblem.empty:
        return l10n.addressProblemEmpty;
      case AddressProblem.malformed:
        return l10n.addressProblemMalformed;
      case AddressProblem.unsupportedScheme:
        return l10n.addressProblemUnsupportedScheme;
      case AddressProblem.invalidPort:
        return l10n.addressProblemInvalidPort;
      case AddressProblem.cleartextRefused:
        return l10n.addressProblemCleartextRefused;
    }
  }
}

/// Refusal of a typed value: icon, colour and text, never colour alone.
class _ProblemNote extends StatelessWidget {
  const _ProblemNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.danger),
          ),
        ),
      ],
    );
  }
}

/// `PRD-MOBILE.md` §7, "Security — transport": an accepted cleartext address is
/// always accompanied by this warning.
class _CleartextWarning extends StatelessWidget {
  const _CleartextWarning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_open_outlined, color: AppColors.danger),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// `FR-MA07` — what a re-discovery added and removed.
///
/// Shown only when the document hash changed, and Primary when it is shown:
/// the UX spec keeps "registry changed since last connect" hidden until it
/// happens. The operations are listed by their key (`"<METHOD> <path>"`),
/// which is the registry's identity for them, because *which* operations
/// appeared is exactly what the operator has to read; the generator's
/// `operationId` — unstable, and in the UX spec's never-shown-by-default list —
/// is not used here.
class _RegistryChangeReport extends StatelessWidget {
  const _RegistryChangeReport({required this.diff});

  final RegistryDiff diff;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.change_circle_outlined,
                color: AppColors.accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  l10n.registryChangedHeadline,
                  style: textTheme.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (diff.isEmpty)
            Text(l10n.registryChangedSame, style: textTheme.bodySmall)
          else ...[
            if (diff.added.isNotEmpty) ...[
              Text(
                l10n.registryChangedAdded(diff.added.length),
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              for (final key in diff.added)
                _OperationLine(operationKey: key, added: true),
            ],
            if (diff.removed.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.registryChangedRemoved(diff.removed.length),
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              for (final key in diff.removed)
                _OperationLine(operationKey: key, added: false),
            ],
          ],
        ],
      ),
    );
  }
}

/// One changed operation. The sign is part of the text, so the two directions
/// stay distinguishable without colour (`FR-MG04`).
class _OperationLine extends StatelessWidget {
  const _OperationLine({required this.operationKey, required this.added});

  final String operationKey;
  final bool added;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            added ? Icons.add_circle_outline : Icons.remove_circle_outline,
            size: 16,
            color: added ? AppColors.success : AppColors.danger,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${added ? '+' : '−'} $operationKey',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
