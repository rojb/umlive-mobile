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

/// One token of an utterance, with the raw text it came from and where it sat.
///
/// The read path needs only the folded form ([utteranceTokens]); the write path
/// has to hand the operator's own words back — the captured values and the
/// read-back (`FR-MC02`, `FR-MC03`) — and folding has already thrown the
/// accents and capitals away. Keeping both forms, plus the offsets, lets every
/// consumer take what it needs from one pass.
final class UtteranceToken {
  const UtteranceToken({
    required this.raw,
    required this.folded,
    required this.start,
    required this.end,
  });

  /// Exactly as it appeared, accents and case intact.
  final String raw;

  /// [foldText] of [raw]: what matching compares.
  final String folded;

  /// Offset of the first character of [raw] in the utterance.
  final int start;

  /// Offset one past the last character of [raw] in the utterance.
  final int end;
}

/// Splits a raw utterance into tokens with their spans.
///
/// Whitespace, punctuation and brackets are the split points; a token whose
/// folded form is empty is dropped rather than kept as a positional hole, so a
/// [UtteranceToken.start]/[UtteranceToken.end] pair may have gaps where
/// separators were.
///
/// `Pérez` is one token whose [UtteranceToken.raw] is `Pérez` and whose
/// [UtteranceToken.folded] is `perez`. The digits survive, because a spoken id
/// ("cliente 42") is a token the resolver has to see.
List<UtteranceToken> utteranceTokenSpans(String utterance) {
  final tokens = <UtteranceToken>[];
  var cursor = 0;
  for (final separator in _nonWord.allMatches(utterance)) {
    _addToken(tokens, utterance, cursor, separator.start);
    cursor = separator.end;
  }
  _addToken(tokens, utterance, cursor, utterance.length);
  return tokens;
}

/// Splits a raw utterance into folded, comparable tokens.
///
/// The recognizer returns punctuation, casing and accents that carry no meaning
/// for matching, so every token is folded exactly the way entity names are
/// (`foldText`) before anything compares them. This is the folded projection of
/// [utteranceTokenSpans], so there is exactly one tokenizer in the app:
/// `¿Cuántos clientes tengo?` becomes `['cuantos', 'clientes', 'tengo']`.
List<String> utteranceTokens(String utterance) =>
    utteranceTokenSpans(utterance).map((token) => token.folded).toList();

void _addToken(
  List<UtteranceToken> tokens,
  String utterance,
  int start,
  int end,
) {
  if (end <= start) return;
  final raw = utterance.substring(start, end);
  final folded = foldText(raw);
  if (folded.isEmpty) return;
  tokens.add(UtteranceToken(raw: raw, folded: folded, start: start, end: end));
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

/// The words that ask the app to *create* a record.
///
/// They are input vocabulary, not copy: the operator says them, the app never
/// renders them. They mark the utterance as a create (`T13`) and are the left
/// edge of the §5.1 value window (`Agregá a Juan Pérez como cliente`).
const Set<String> createTriggers = <String>{
  'agrega',
  'agregar',
  'agregame',
  'crea',
  'crear',
  'creame',
  'inserta',
  'insertar',
  'registra',
  'registrar',
  'anota',
  'anotar',
  'carga',
  'cargar',
  'alta',
  'suma',
  'sumar',
};

/// The words that ask the app to *delete* a record (`FR-MC05`).
///
/// They are input vocabulary, not copy: the operator says them, the app never
/// renders them. They open the destructive conversation, which names one target
/// and restates its identity before anything is sent. They are also the reason
/// a delete can never fall through to the read path — *borrá el cliente 1* would
/// otherwise find the `get` role and **read** the record it was asked to
/// destroy, which is a lie about what the app did.
const Set<String> deleteTriggers = <String>{
  'borra',
  'borrar',
  'borrame',
  'elimina',
  'eliminar',
  'eliminame',
  'suprime',
  'suprimir',
  'quita',
  'quitar',
  'saca',
  'sacar',
  'remueve',
  'remover',
};

/// The words that ask the app to *modify* a record: **not implemented**.
///
/// They are input vocabulary, not copy, and they exist for one reason: an
/// update is a write this build does not perform, so it has to be refused with
/// the entity named instead of falling through to the read path, where
/// *modificá el cliente 1* would be answered with a listing. An update needs
/// the record read first, which is its own task; until then this set is the
/// guard that keeps the refusal honest.
const Set<String> updateTriggers = <String>{
  'modifica',
  'modificar',
  'modificame',
  'actualiza',
  'actualizar',
  'actualizame',
  'cambia',
  'cambiar',
  'cambiame',
  'edita',
  'editar',
  'editalo',
};

/// The words that accept a pending write (`FR-MC03`).
///
/// They are input vocabulary, not copy: the operator says them, the app never
/// renders them, and the band's *Confirmar* control submits one of them through
/// the same resolution path as speech so the affirmative rule exists once.
const Set<String> affirmativeAnswers = <String>{
  'si',
  'confirmo',
  'confirmar',
  'confirma',
  'confirmado',
  'dale',
  'ok',
  'okey',
  'listo',
  'correcto',
  'hacelo',
  'mandale',
  'adelante',
  'afirmativo',
  'acuerdo',
};

/// The words that discard a pending write (`FR-MC03`).
///
/// They are input vocabulary, not copy, for the same reason and with the same
/// single-path rule as [affirmativeAnswers]: the band's *Cancelar* control
/// submits one of these rather than carrying a second implementation of what a
/// cancel means.
const Set<String> negativeAnswers = <String>{
  'no',
  'cancelar',
  'cancela',
  'cancelalo',
  'cancelala',
  'dejalo',
  'dejala',
  'espera',
  'para',
  'parar',
  'nada',
  'anular',
  'anula',
  'abortar',
  'atras',
};

/// The connector that introduces the entity after a create value.
///
/// It is input vocabulary, not copy. It exists for one narrow shape, the §5.1
/// one — *Agregá a Juan Pérez como cliente* — where `como` sits between the
/// value and the entity mention. Any other phrasing is not guessed at: the
/// field is simply asked for, one at a time (`FR-MC02`).
const Set<String> createValueConnectors = <String>{'como'};

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
