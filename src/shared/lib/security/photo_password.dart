import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';

/// SFR-1 input policy. Strings belong to the caller; Dart cannot erase them.
/// Returned bytes belong to the caller and must be cleared after secureCopy.
abstract final class PhotoPassword {
  static Uint8List encode(String password, {String? confirmation}) {
    // Bound work before iterating. One scalar occupies at most two UTF-16 units.
    if (password.length < 12 || password.length > 256) {
      throw const SecurityFailure(SecurityFailureCode.invalidPassword);
    }
    var count = 0;
    int? first;
    var repeated = true;
    var whitespaceOnly = true;
    for (var i = 0; i < password.length; i++) {
      var scalar = password.codeUnitAt(i);
      if (scalar >= 0xd800 && scalar <= 0xdbff) {
        if (++i >= password.length) {
          throw const SecurityFailure(SecurityFailureCode.invalidPassword);
        }
        final low = password.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) {
          throw const SecurityFailure(SecurityFailureCode.invalidPassword);
        }
        scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
      } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
        throw const SecurityFailure(SecurityFailureCode.invalidPassword);
      }
      if (scalar <= 0x1f || (scalar >= 0x7f && scalar <= 0x9f)) {
        throw const SecurityFailure(SecurityFailureCode.invalidPassword);
      }
      count++;
      first ??= scalar;
      repeated = repeated && scalar == first;
      whitespaceOnly = whitespaceOnly && _isWhitespace(scalar);
    }
    if (count < 12 || count > 128 || repeated || whitespaceOnly) {
      throw const SecurityFailure(SecurityFailureCode.invalidPassword);
    }
    if (confirmation != null && password != confirmation) {
      throw const SecurityFailure(SecurityFailureCode.passwordMismatch);
    }
    // No trimming, case folding, normalization or malformed-input replacement.
    return utf8.encode(password);
  }

  // Explicit Unicode White_Space set, independent of platform regex behavior.
  static bool _isWhitespace(int c) =>
      c == 0x20 ||
      c == 0xa0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200a) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202f ||
      c == 0x205f ||
      c == 0x3000 ||
      c == 0xfeff;
}
