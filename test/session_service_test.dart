import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/session_service.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registerSession completes without throwing', () async {
    // registerSession is best-effort and should swallow plugin errors in test env
    await SessionService.registerSession('00000000-0000-0000-0000-000000000000');
  });
}
