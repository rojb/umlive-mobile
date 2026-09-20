import 'package:flutter/foundation.dart';

/// The operator's explicit request to see the machinery (`T23`, `FR-ME06`).
///
/// Technical mode is not a preference the app acts on by itself. The UX spec
/// puts the technical detail per turn **hidden behind an explicit toggle**
/// (Pass 2, "System"), and the affordance is exactly that — a toggle: *"Reveal
/// technical detail → a toggle in the app bar, persistent across turns once
/// enabled"* (Pass 3). The Author's and the Evaluator's view is turned on by a
/// person and by nothing else, which is why the only mutator here is [toggle]
/// and there is no `enabled = true` to call: no debug build, no failure and no
/// discovery result may ever turn this on behind the operator's back.
///
/// It starts **off** (Pass 4, "Defaults introduced": *technical mode off*,
/// because the Operator is the default persona) and it lives in memory only,
/// deliberately, for this release. What the spec asks for is persistence
/// **across turns**, and a turn does not outlive the process — so surviving a
/// relaunch is not part of the requirement and this is not an oversight. The
/// app stores the things a relaunch must not lose (the backend profile, the
/// registry, the read cache and the queue); this is not one of them. A later
/// release that wants it to survive a launch is taking a storage decision
/// knowingly, not inheriting one by accident.
class TechnicalMode extends ChangeNotifier {
  bool _enabled = false;

  /// Whether the operator asked to see the machinery. Off until they do.
  bool get enabled => _enabled;

  /// Flips the operator's request, and the only way it ever changes.
  void toggle() {
    _enabled = !_enabled;
    notifyListeners();
  }
}
