/// The single definition of text folding in this app.
///
/// Folding is what makes two spellings of the same word comparable: the
/// backend's ASCII-folded route word and the schema name that carries the
/// original UML spelling (`Dirección` / `direccion`), or a spoken utterance
/// and the entity name it names (`¿cuántos clientes tengo?` / `Cliente`).
library;

/// Folds [value] to ASCII, lower-case, alphanumerics only.
///
/// Accents are folded rather than stripped (`á` to `a`, `ñ` to `n`, `ç` to
/// `c`), in both cases, and everything that is not `[a-z0-9]` is dropped:
/// `Dirección` becomes `direccion`, `ItemPedido` and `item-pedido` both become
/// `itempedido`.
///
/// There is exactly one copy of this function, and a second one would be a
/// defect. Two callers depend on the *same* equivalence to agree:
///
/// - the OpenAPI parser, for the schema-name/route-word agreement that recovers
///   an entity's un-folded domain name (`docs/architecture.md` §11, `FR-MC07`);
/// - the deterministic resolver, which matches a transcribed utterance and the
///   numeric/textual values in it against those entity names (`FR-MC04`).
///
/// If the two folded differently, the parser would confirm a name the resolver
/// could never match, and the failure would be a silently unresolved utterance
/// — the hardest kind here to attribute to its cause.
String foldText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    final folded = _accents[character];
    if (folded != null) {
      buffer.write(folded);
    } else if (_alphanumeric.hasMatch(character)) {
      buffer.write(character);
    }
  }
  return buffer.toString();
}

final RegExp _alphanumeric = RegExp(r'[a-z0-9]');

/// The accented characters the two languages this app reads can produce. It is
/// a fold table, not a transliteration: every entry maps to the ASCII letter
/// the recognizer, the generator and the operator all type instead.
const Map<String, String> _accents = <String, String>{
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};
