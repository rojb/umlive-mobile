import '../l10n/app_localizations.dart';
import '../openapi/registry.dart';

/// Turns the discovered registry into the domain-language sentences the UX
/// spec asks for.
///
/// The names come from the registry and nowhere else: `FR-MC07` derives the
/// vocabulary from the schema, so `/api/direccion` is still shown and spoken as
/// "dirección". Nothing here knows a domain word; the connectors come from
/// `AppLocalizations` because even a comma is user-facing copy.

/// How many entity names the assistant names before it stops counting.
///
/// The UX spec allows three examples in the greeting (Pass 4); the Connect
/// success state lists all of them, because there the names *are* the evidence.
const int assistantScopeExamples = 3;

/// Joins [names] the way a Spanish list reads: `a, b y c`.
String joinEntityNames(AppLocalizations l10n, List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return names.first;
  final head = names.sublist(0, names.length - 1).join(l10n.entityListSeparator);
  return '$head${l10n.entityListConjunction}${names.last}';
}

/// The assistant's first turn, built from what the backend actually exposes.
///
/// With no registry at all it falls back to the intent-only greeting; with a
/// registry that declares no operation it says exactly that, because an empty
/// conversation surface would read as a failure (`FR-MA06`, UX spec Pass 6).
String scopeGreeting(AppLocalizations l10n, ApiRegistry registry) {
  if (registry.operations.isEmpty) {
    return l10n.assistantGreetingNoOperations;
  }
  final names = registry.entities
      .map((entity) => lowerFirst(entity.name))
      .toList();
  final shown = names.take(assistantScopeExamples).toList();
  final joined = joinEntityNames(l10n, shown);
  return names.length > shown.length
      ? l10n.assistantGreetingScopeMore(joined)
      : l10n.assistantGreetingScope(joined);
}

/// Lower-cases the first character of a recovered entity name.
///
/// The schema carries it as a type name (`Dirección`); inside a sentence a
/// Spanish common noun is lower-case. The rest of the name is untouched, so the
/// un-folded spelling and its accents survive intact (`FR-MC07`).
String lowerFirst(String value) {
  if (value.isEmpty) return value;
  return value[0].toLowerCase() + value.substring(1);
}
