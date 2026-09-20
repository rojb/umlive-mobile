/// Spanish input vocabulary and noun morphology, in one place.
///
/// **This is not user-facing copy.** Every sentence the app says lives in
/// `lib/l10n/app_es.arb`; a literal string in Dart is a defect. What lives
/// here is the other kind of Spanish: the words an operator *says* to ask for
/// something, the words that carry no meaning on their own, and the plural
/// rule the answer needs. None of it is translatable, because none of it is
/// addressed to the reader.
///
/// It is Spanish and it lives in a file of its own because Spanish is the
/// language this app listens in (`PRD-MOBILE.md` §7). The resolver must not
/// scatter individual words of it — a vocabulary split across call sites is a
/// vocabulary nobody can review.
library;

import '../core/text_fold.dart';

/// Splits a raw utterance into folded, comparable tokens.
///
/// The recognizer returns punctuation, casing and accents that carry no
/// meaning for matching, so every token is folded exactly the way entity names
/// are (`foldText`) before anything compares them. Whitespace, punctuation and
/// brackets are the split points; a folded token that is empty is dropped
/// rather than kept as a positional hole.
///
/// The digits survive, because a spoken id ("cliente 42") is a token the
/// resolver has to see.
///
/// `¿Cuántos clientes tengo?` becomes `['cuantos', 'clientes', 'tengo']`, and
/// `Pérez` stays one token (`perez`).
List<String> utteranceTokens(String utterance) {
  final tokens = <String>[];
  for (final piece in utterance.split(_nonWord)) {
    final folded = foldText(piece);
    if (folded.isNotEmpty) tokens.add(folded);
  }
  return tokens;
}

/// Anything that is not a letter with a Spanish accent or a digit. It is the
/// split point of [utteranceTokens] and nothing else.
final RegExp _nonWord = RegExp(r'[^0-9A-Za-zÀ-ÖØ-öø-ÿ]+');

/// The words that ask *how many*, which is a count and never a listing.
///
/// Only the four gendered/numbered forms of one interrogative: `cuántos`,
/// `cuántas`, `cuánto`, `cuánta`. Nothing else in Spanish asks for a count in
/// a form this app can answer, so nothing else is added here.
const Set<String> countTriggers = <String>{
  'cuantos',
  'cuantas',
  'cuanto',
  'cuanta',
};

/// The words that ask to *see* the collection, which is a listing.
///
/// Three families, all of them requests for a read: the `lista`/`listado`
/// family (`listar`, `listame`, `listalos`, `listalas` — the listed enclitic
/// forms of the same verb), the `mostrar` family (`muestra`, `muestrame`,
/// `mostra`), and the small verbs `dame`, `decime`, `decir`, `ver`, `enumera`,
/// `enumerar`. `cual`/`cuales` and `todos`/`todas` are here because
/// "¿cuáles son los clientes?" and "todos los clientes" are the same request
/// with the verb elided, which is how it is actually spoken. `hay` closes the
/// set: "¿qué clientes hay?".
///
/// Every entry is a verb or a determiner the operator says, never a noun.
const Set<String> readListTriggers = <String>{
  'lista',
  'listar',
  'listame',
  'listalos',
  'listalas',
  'listado',
  'mostrar',
  'muestra',
  'muestrame',
  'mostra',
  'dame',
  'decime',
  'decir',
  'cual',
  'cuales',
  'todos',
  'todas',
  'ver',
  'enumera',
  'enumerar',
  'hay',
};

/// The words that carry grammar and no request.
///
/// They are here so that "dame los clientes", "¿cuáles son los clientes de
/// Lima?" without more and "quiero ver los clientes" all reduce to the same
/// thing: an article, a preposition or a courtesy verb does not change what
/// was asked. Their only role in the resolver is one specific rule — an
/// utterance made *only* of these and of the entity's own name is a request to
/// read that entity, because there is nothing else it could be asking for.
///
/// The set is deliberately small and closed. Adding a word here makes it
/// invisible to the "this is not a read" rule, so an unjustified entry would
/// let a write be answered with a listing.
const Set<String> utteranceFillers = <String>{
  'el',
  'la',
  'los',
  'las',
  'un',
  'una',
  'unos',
  'unas',
  'de',
  'del',
  'al',
  'a',
  'mi',
  'mis',
  'me',
  'te',
  'se',
  'por',
  'favor',
  'para',
  'que',
  'con',
  'sin',
  'y',
  'o',
  'en',
  'es',
  'son',
  'quiero',
  'quisiera',
  'necesito',
  'puedo',
};

/// The plural of [noun], by the general rule of Spanish morphology.
///
/// - a word ending in `z` drops the `z` and takes `ces` (`lápiz` → `lapices`);
/// - a word ending in a vowel takes `s` (`cliente` → `clientes`);
/// - anything else takes `es` (`ciudad` → `ciudades`).
///
/// This is a morphology rule, not a dictionary, and it is worth saying what
/// that limit is. Invariant nouns are not special-cased (`crisis` → `crisises`,
/// which is wrong). Nouns ending in an accented vowel followed by `s` behave
/// differently from one another and are not special-cased either (`autobús` →
/// `autobuses` drops the accent, `país` → `países` keeps it). Neither are the
/// ones that *gain* an accent when they grow (`examen` → `exámenes`).
///
/// What it does cover is the case that matters here: an entity name ending in
/// an accented vowel plus `n` loses the written accent in the plural, because
/// the stress moves back one syllable — `Dirección` → `direcciones`, which is
/// an entity of the fixture backend and not a hypothetical.
///
/// It exists because the answer needs a plural noun next to a count and the
/// backend publishes no vocabulary for it — the entity name is the only noun
/// available, and a rule the app can state is better than a word list the app
/// would have to invent. [noun] arrives in sentence case (`lowerFirst`), which
/// is why only lower-case accented vowels appear in the table below.
String pluralizeSpanishNoun(String noun) {
  if (noun.isEmpty) return noun;
  final last = noun[noun.length - 1].toLowerCase();
  if (last == 'z') {
    return '${noun.substring(0, noun.length - 1)}ces';
  }
  if (_vowels.contains(last)) {
    return '${noun}s';
  }
  final lower = noun.toLowerCase();
  for (final suffix in _accentedPluralSuffixes.keys) {
    if (lower.endsWith(suffix)) {
      final stem = noun.substring(0, noun.length - suffix.length);
      return '$stem${_accentedPluralSuffixes[suffix]}';
    }
  }
  return '${noun}es';
}

/// The `-ión` family: an accented vowel followed by `n` loses the accent when
/// the plural adds a syllable and pulls the stress back.
const Map<String, String> _accentedPluralSuffixes = <String, String>{
  'án': 'anes',
  'én': 'enes',
  'ín': 'ines',
  'ón': 'ones',
  'ún': 'unes',
};

const Set<String> _vowels = <String>{
  'a',
  'e',
  'i',
  'o',
  'u',
  'á',
  'é',
  'í',
  'ó',
  'ú',
};
