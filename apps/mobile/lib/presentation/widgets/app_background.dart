import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Page backdrop used by every screen.
///
/// Near-black [AppColors.bg] plus the emerald bloom of the reference design,
/// bleeding from the top edge. It is painted *behind* the app bar as well, so
/// whatever [Scaffold] it wraps must keep `backgroundColor: Colors.transparent`
/// or it will cover the bloom with a flat fill.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Kept as a fallback only. It is never painted while a gradient is set:
        // see the note on the last gradient stop below.
        color: AppColors.bg,
        // Centred above the top edge, so only the lower half of the bloom is
        // visible and it reads as light entering the screen from off-page.
        gradient: RadialGradient(
          center: const Alignment(0, -1.15),
          radius: 1.25,
          colors: [
            AppColors.bgGlow.withValues(alpha: 0.55),
            AppColors.bgGlow.withValues(alpha: 0.16),
            // This last stop must stay fully opaque. Flutter's
            // `_BoxDecorationPainter._getBackgroundPaint` puts both
            // `decoration.color` and the gradient into a single `Paint`, and a
            // `Paint` carrying a shader ignores its color. So nothing fills the
            // flat background underneath the gradient, and a transparent tail
            // here exposes the FlutterView's black instead of `AppColors.bg`.
            AppColors.bg,
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: child,
    );
  }
}
