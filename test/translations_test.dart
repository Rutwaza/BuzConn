// Run:  flutter test test/translations_test.dart
// Lists every tr('...') text in lib/ that has no Kinyarwanda translation yet.
// Fails only if a translation is empty, so it never blocks a build.
import 'dart:io';

import 'package:businessfinder/core/i18n/rw_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Kinyarwanda translations', () {
    final found = <String>{};
    final pattern = RegExp(r"""tr\((['"])((?:(?!\1)[^\\$\n]|\\.)*)\1\)""");
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final m in pattern.allMatches(f.readAsStringSync())) {
        found.add(m.group(2)!.replaceAll(r"\'", "'").replaceAll(r'\n', '\n'));
      }
    }
    final missing = found.where((s) => !rwStrings.containsKey(s)).toList()..sort();
    // ignore: avoid_print
    print('${found.length} texts, ${missing.length} without Kinyarwanda:\n  ${missing.join('\n  ')}');
    expect(rwStrings.values.where((v) => v.trim().isEmpty), isEmpty);
  });
}
