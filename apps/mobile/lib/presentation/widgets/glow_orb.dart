import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The capture visualisation: a soft gradient circle inside a wide emerald
/// halo.
///
/// The orb carries the two facts the operator has to be able to tell apart
/// without reading anything: *the microphone is open* and *the assistant is
/// talking*. It owns **three motions, one per state, and they are mutually
/// exclusive**:
///
/// - **idle** ([listening] false, [speaking] false) — provably static, and the
///   quietest of the three. Nothing here reads a clock, starts a ticker or
///   changes on rebuild: two screenshots taken a second apart are identical.
///   `FR-MG05`: a glow that breathes while the microphone is closed reads as
///   "it is hearing me", and that is a correctness bug, not decoration.
/// - **listening** ([listening] true) — motion driven **by the [amplitude] it
///   is handed**, never by a clock. The microphone is the only thing allowed to
///   move this orb, so the scale and the halo are a function of the real level
///   and of nothing else.
/// - **speaking** ([speaking] true) — a **clock-driven** rhythm: a soft pulse
///   and a breathing ring on a steady beat, started only while [speaking] is
///   true and stopped otherwise, so no ticker runs in the other two states. It
///   is a different *motion*, not a louder listening state: listening follows a
///   voice and has no ring, speaking follows a clock and wears one, so the two
///   are distinguishable **without colour** (`FR-MG04`). The caption below the
///   orb says which one it is.
///
/// [amplitude] is the real microphone level as a `0..1` fraction of full scale
/// and [listening] says whether the microphone is actually open. Both are
/// consumed here and nowhere else.
///
/// State order, stated once: **speaking wins** when both were ever true. They
/// should never be — the capture control refuses to open the microphone while
/// the assistant talks — but the widget must not be ambiguous if they are.
class GlowOrb extends StatefulWidget {
  const GlowOrb({
    super.key,
    this.size = AppSizes.orb,
    this.amplitude = 0,
    this.listening = false,
    this.speaking = false,
  }) : assert(amplitude >= 0 && amplitude <= 1, 'amplitude is 0..1');

  /// Diameter of the orb itself. The halo is painted outside this box.
  final double size;

  /// Microphone level, `0..1`. Only read in the listening state.
  final double amplitude;

  /// Whether the microphone is open. False freezes the orb.
  final bool listening;

  /// Whether the assistant is speaking right now (`T26`). Drives the one
  /// clock-driven motion, and takes precedence over [listening].
  final bool speaking;

  @override
  State<GlowOrb> createState() => _GlowOrbState();
}

class _GlowOrbState extends State<GlowOrb>
    with SingleTickerProviderStateMixin {
  /// The speaking rhythm's clock. It is *stopped* in every state but speaking,
  /// which is what keeps the idle orb free of any ticker.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    // A calm, slow breath. Slower than a heartbeat, so it reads as "the app is
    // talking", not as an alarm.
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    if (widget.speaking) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(GlowOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.speaking == oldWidget.speaking) return;
    if (widget.speaking) {
      _breath.repeat(reverse: true);
    } else {
      // The other two states must run no ticker. Stopping and resetting here is
      // what makes the idle state provably static and the listening state a
      // function of the microphone alone.
      _breath.stop();
      _breath.value = 0;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Speaking wins: it is the later, more surprising fact, and the operator's
    // one concern while it lasts is stopping it.
    if (widget.speaking) {
      return AnimatedBuilder(
        animation: _breath,
        builder: (context, _) => _buildSpeaking(),
      );
    }

    final bool listening = widget.listening;
    final double level = listening ? widget.amplitude : 0.0;

    // Idle halo: dim and fixed — with `listening` false every value below is a
    // constant. Live halo: brighter and wider, and still only a function of the
    // level it is handed.
    final double haloAlpha = listening ? 0.30 + 0.45 * level : 0.14;
    final double haloBlur = widget.size * (0.45 + 0.35 * level);
    final double haloSpread = widget.size * (0.06 + 0.10 * level);

    return _buildCircle(
      // Deepened from the original 0.05 so dictating visibly moves the orb: the
      // response has to be legible, not merely present.
      scale: 1 + 0.10 * level,
      shadows: [
        BoxShadow(
          color: AppColors.accent.withValues(alpha: haloAlpha),
          blurRadius: haloBlur,
          spreadRadius: haloSpread,
        ),
      ],
    );
  }

  /// The clock-driven speaking motion.
  ///
  /// Deliberately calmer than the listening halo (whose alpha climbs to 0.75)
  /// and structurally different from it: a soft pulse on the core, plus a
  /// **breathing ring** — a sharp edge, not a blurred glow — that expands and
  /// fades on the beat. Listening has no ring; speaking always has one.
  Widget _buildSpeaking() {
    final double breath = _breath.value; // 0 → 1 → 0, on the controller's beat.

    final double haloAlpha = 0.16 + 0.08 * breath;
    final double ringAlpha = 0.40 - 0.16 * breath;

    return _buildCircle(
      scale: 1 + 0.02 * breath,
      shadows: [
        BoxShadow(
          color: AppColors.accent.withValues(alpha: haloAlpha),
          blurRadius: widget.size * (0.45 + 0.06 * breath),
          spreadRadius: widget.size * (0.06 + 0.02 * breath),
        ),
        // blurRadius 0 makes this a ring: a hard-edged band painted behind the
        // circle, so only the part outside it is visible. Its radius grows
        // while its alpha shrinks, and back — the breath.
        BoxShadow(
          color: AppColors.accent.withValues(alpha: ringAlpha),
          blurRadius: 0,
          spreadRadius: widget.size * (0.09 + 0.05 * breath),
        ),
      ],
    );
  }

  Widget _buildCircle({
    required double scale,
    required List<BoxShadow> shadows,
  }) {
    return SizedBox.square(
      dimension: widget.size,
      child: Transform.scale(
        scale: scale,
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
            boxShadow: shadows,
          ),
        ),
      ),
    );
  }
}
