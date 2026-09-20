import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The capture visualisation: a soft gradient circle inside a wide emerald
/// halo.
///
/// [amplitude] is the real microphone level as a `0..1` fraction of full scale
/// and [listening] says whether the microphone is actually open. Both are
/// consumed here and nowhere else.
///
/// The idle state is deliberately static *and* dim. `FR-MG05` and the
/// affordance rules in the UX spec both say the same thing: if the orb breathes
/// while the microphone is closed, the user reads it as "it is hearing me" and
/// that is a correctness bug, not decoration. Any motion added here must be
/// gated on [listening], and T8 is where the real amplitude is bound.
class GlowOrb extends StatelessWidget {
  const GlowOrb({
    super.key,
    this.size = AppSizes.orb,
    this.amplitude = 0,
    this.listening = false,
  }) : assert(amplitude >= 0 && amplitude <= 1, 'amplitude is 0..1');

  /// Diameter of the orb itself. The halo is painted outside this box.
  final double size;

  /// Microphone level, `0..1`. Ignored while [listening] is false.
  final double amplitude;

  /// Whether the microphone is open. False freezes the halo.
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final level = listening ? amplitude : 0.0;

    // Idle halo: dim, fixed. Live halo: brighter and wider, but still only a
    // function of the level it is handed.
    final haloAlpha = listening ? 0.30 + 0.25 * level : 0.14;
    final haloBlur = size * (0.45 + 0.25 * level);
    final haloSpread = size * (0.06 + 0.04 * level);

    return SizedBox.square(
      dimension: size,
      child: Transform.scale(
        scale: 1 + 0.05 * level,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.orbTop, AppColors.orbBottom],
            ),
            // Elevation is glow, not drop shadow (UX spec, "Shape and
            // elevation"). The shadow doubles as the soft edge of the orb.
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: haloAlpha),
                blurRadius: haloBlur,
                spreadRadius: haloSpread,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
