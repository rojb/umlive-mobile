import 'dart:typed_data';

/// SHA-256 (FIPS 180-4) over a byte sequence, returned as lowercase hex.
///
/// Implemented here rather than taken from `package:crypto`: that package is a
/// transitive dependency only, and `FR-MA07` needs exactly one hash — change
/// detection of the OpenAPI document (`docs/architecture.md` §11). Adding a
/// declared dependency for this would buy nothing the twenty lines below do
/// not already do.
///
/// The implementation is the plain reference algorithm; it is verified against
/// `sha256sum` on the live description document.
abstract final class Sha256 {
  /// Round constants: the first 32 bits of the fractional parts of the cube
  /// roots of the first sixty-four primes.
  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  /// The lowercase hexadecimal digest of [bytes].
  static String hex(List<int> bytes) {
    final digest = digestWords(bytes);
    final buffer = StringBuffer();
    for (final word in digest) {
      buffer.write(word.toRadixString(16).padLeft(8, '0'));
    }
    return buffer.toString();
  }

  /// The eight 32-bit words of the digest, in big-endian order.
  static Uint32List digestWords(List<int> message) {
    final h = Uint32List.fromList(const <int>[
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]);

    // Pad to a whole number of 64-byte blocks: the message, one 0x80 byte,
    // zeroes, then the bit length as a 64-bit big-endian integer.
    final bitLength = message.length * 8;
    final paddedLength = ((message.length + 9 + 63) ~/ 64) * 64;
    final padded = Uint8List(paddedLength);
    for (var i = 0; i < message.length; i++) {
      padded[i] = message[i] & 0xff;
    }
    padded[message.length] = 0x80;
    for (var i = 0; i < 8; i++) {
      padded[paddedLength - 1 - i] = (bitLength >> (8 * i)) & 0xff;
    }

    final schedule = Uint32List(64);
    for (var block = 0; block < paddedLength; block += 64) {
      for (var i = 0; i < 16; i++) {
        final at = block + i * 4;
        schedule[i] =
            (padded[at] << 24) |
            (padded[at + 1] << 16) |
            (padded[at + 2] << 8) |
            padded[at + 3];
      }
      for (var i = 16; i < 64; i++) {
        final w15 = schedule[i - 15];
        final w2 = schedule[i - 2];
        final s0 = _rotateRight(w15, 7) ^ _rotateRight(w15, 18) ^ (w15 >> 3);
        final s1 = _rotateRight(w2, 17) ^ _rotateRight(w2, 19) ^ (w2 >> 10);
        schedule[i] =
            (schedule[i - 16] + s0 + schedule[i - 7] + s1) & 0xffffffff;
      }

      var a = h[0];
      var b = h[1];
      var c = h[2];
      var d = h[3];
      var e = h[4];
      var f = h[5];
      var g = h[6];
      var hh = h[7];

      for (var i = 0; i < 64; i++) {
        final s1 = _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
        final choose = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (hh + s1 + choose + _k[i] + schedule[i]) & 0xffffffff;
        final s0 = _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
        final majority = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + majority) & 0xffffffff;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h[0] = (h[0] + a) & 0xffffffff;
      h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff;
      h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff;
      h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff;
      h[7] = (h[7] + hh) & 0xffffffff;
    }

    return h;
  }

  static int _rotateRight(int value, int bits) =>
      ((value >> bits) | (value << (32 - bits))) & 0xffffffff;
}
