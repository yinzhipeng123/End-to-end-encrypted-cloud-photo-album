import 'dart:convert';

import 'package:encrypted_photo_shared/security/photo_password.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'strict UTF-8 preserves spaces, case and Unicode normalization form',
    () {
      for (final text in [
        '  lantern River carpet  ',
        '十二三个不相关的词语组合而成',
        'Lantern River carpet',
        'e\u0301 lantern river carpet',
        '\u00e9 lantern river carpet',
        '🌄🌅🌆🌇🌈🌉🌊🌋🌌🌍🌎🌏',
      ]) {
        final bytes = PhotoPassword.encode(text, confirmation: text);
        expect(bytes, utf8.encode(text));
        bytes.fillRange(0, bytes.length, 0);
      }
    },
  );

  test('counts Unicode scalars and accepts the 12/128 boundaries', () {
    for (final text in ['abcdef123456', '${'🌄' * 127}🌅']) {
      final bytes = PhotoPassword.encode(text);
      bytes.fillRange(0, bytes.length, 0);
    }
  });

  test('rejects weak, malformed, overlong and control inputs', () {
    for (final text in [
      '',
      'abcdef12345',
      '${'a' * 128}b',
      '${'🌄' * 128}🌅',
      'abcdefghijkl\u0000',
      'abcdefghijkl\u0085',
      'abcdefghijkl\n',
      'abcdefghijkl\ud800',
      'abcdefghijkl\udfff',
      'abcdefghijkl\ud800z',
      ' ' * 12,
      '${' ' * 6}${'\u3000' * 6}',
      'x' * 12,
      '🌄' * 12,
    ]) {
      expect(
        () => PhotoPassword.encode(text),
        throwsA(
          isA<SecurityFailure>().having(
            (error) => error.code,
            'code',
            SecurityFailureCode.invalidPassword,
          ),
        ),
      );
    }
  });

  test('confirmation must be exact; errors never include the input', () {
    const password = 'lantern river carpet';
    try {
      PhotoPassword.encode(password, confirmation: '$password ');
      fail('mismatching confirmation was accepted');
    } on SecurityFailure catch (error) {
      expect(error.code, SecurityFailureCode.passwordMismatch);
      expect(error.toString(), isNot(contains(password)));
    }
  });
}
