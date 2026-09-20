import 'package:flutter/material.dart';

/// Design tokens for the whole app.
///
/// Read off `mobile-inspo.webp` — three screens of a dark, emerald-accented
/// voice assistant — and transcribed into `PRD-MOBILE-ux-spec.md`
/// ("Visual Specifications"). The hex values are close reads of that image,
/// not values its author published, so they are a starting palette to refine
/// against the file.
///
/// Nothing in the app may name a colour, radius or text size directly: every
/// value comes from here. That is what keeps the three outcome states
/// (done / queued / not understood) distinguishable as a family instead of
/// drifting apart screen by screen.
abstract final class AppColors {
  /// Page background: near-black with a distinct green cast, never neutral grey.
  static const Color bg = Color(0xFF0A1513);

  /// The emerald bloom behind the orb and bleeding from the top edge. It is the
  /// only "colour" in large areas.
  static const Color bgGlow = Color(0xFF1B6B52);

  /// Cards, assistant bubbles, chips. Very low contrast against [bg]: the design
  /// separates by radius and glow, not by value.
  static const Color surface = Color(0xFF16232A);

  /// Saturated emerald, used sparingly and only on the two primary actions
  /// (microphone, send).
  static const Color accent = Color(0xFF14B87E);

  /// Top of the orb gradient: bright cyan-teal.
  static const Color orbTop = Color(0xFF2EE6C8);

  /// Bottom of the orb: near-white mint.
  static const Color orbBottom = Color(0xFFE6F7EF);

  /// Near-white, slightly warm-green.
  static const Color textPrimary = Color(0xFFE9F1EE);

  /// Secondary copy, and the *unconfirmed tail* of a live transcript.
  static const Color textMuted = Color(0xFF8FA3A0);

  /// Glyphs on the accent fill.
  static const Color onAccent = Color(0xFFFFFFFF);

  /// The user's own messages are the only pure-white surface in the app.
  static const Color userBubble = Color(0xFFFFFFFF);

  /// Text on [userBubble].
  static const Color onUserBubble = Color(0xFF0A1513);

  /// Hairline used by outline-shaped turns and cards. The reference has no
  /// borders; the queued and not-understood treatments need one to be legible
  /// without colour.
  static const Color border = Color(0xFF2A3A3F);

  /// Destructive affordance. Never the only signal of an outcome: it always
  /// travels with an icon and with text.
  static const Color danger = Color(0xFFFF6B6B);

  /// Transient success mark, paired with an icon and text.
  static const Color success = Color(0xFF2EE6C8);
}

/// Text roles. Sizes are the ranges the UX spec fixes for each role.
abstract final class AppTextSizes {
  static const double greeting = 28;
  static const double transcript = 21;
  static const double body = 16;
  static const double caption = 14;
  static const double chip = 14;
}

/// Corner radii. Buttons are circular and get their radius from their size,
/// not from this table.
abstract final class AppRadii {
  static const Radius card = Radius.circular(20);
  static const Radius cardSmall = Radius.circular(18);
  static const Radius pill = Radius.circular(999);

  static const BorderRadius cardAll = BorderRadius.all(card);
  static const BorderRadius cardSmallAll = BorderRadius.all(cardSmall);
  static const BorderRadius pillAll = BorderRadius.all(pill);
}

/// Interactive sizes. The capture control is the largest element on screen and
/// lives in the bottom third, reachable one-handed (FR-MG02).
abstract final class AppSizes {
  /// Diameter of the microphone control and of the orb.
  static const double orb = 180;

  /// Diameter of the flanking secondary actions.
  static const double secondaryAction = 44;

  /// Minimum touch target, per Material and per the accessibility pass.
  static const double minTouchTarget = 48;
}

/// Spacing scale. Comfortable rather than compact for anything interactive.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}
