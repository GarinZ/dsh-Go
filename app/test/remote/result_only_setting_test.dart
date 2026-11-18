import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('results-only defaults off and preserves the explicit choice across containers', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    final preference = first.read(remoteResultOnlyProvider.notifier);
    await preference.ready;
    expect(first.read(remoteResultOnlyProvider), isFalse);
    await preference.set(true);
    expect((await SharedPreferences.getInstance()).getBool(RemoteResultOnlyController.prefsKey), isTrue);
    first.dispose();

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(remoteResultOnlyProvider.notifier).ready;
    expect(restored.read(remoteResultOnlyProvider), isTrue);
    await restored.read(remoteResultOnlyProvider.notifier).set(false);
    expect((await SharedPreferences.getInstance()).getBool(RemoteResultOnlyController.prefsKey), isFalse);
  });
}
