import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows prescreen page and detector script are bundled', () async {
    final page = await rootBundle.loadString('assets/photo_prescreen/index.html');
    final script = await rootBundle.loadString('web/photo_prescreen.js');

    // The page must load the detector next to it (the host writes both into
    // one temp directory) and report results on the channel Dart listens to.
    expect(page, contains('src="photo_prescreen.js"'));
    expect(page, contains('PrescreenResult'));
    expect(page, contains('PrescreenReady'));
    expect(script, contains('window.MatchMePhotoPrescreen'));
  });
}
