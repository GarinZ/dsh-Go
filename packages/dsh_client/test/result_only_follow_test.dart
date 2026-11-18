import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';
import 'support/history_fill_harness.dart';

void main() {
  test('result-only omission marker covers its dropped run without a resync', () async {
    final host = await FakeDsh.start();
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    final opened = <String>[];
    final events = <DshEvent>[];
    final errors = <Object>[];
    final sawTail = Completer<void>();
    try {
      host.onOpen = (socket, id, endpoint, payload) {
        if (endpoint != 'session/follow') return;
        opened.add(endpoint);
        socket.item(id, historySnapshot(0, [historyFrame(0)]));
        socket.item(id, {
          'type': 'event',
          'event': {
            'type': 'log/omitted',
            'seq': 3,
            'time': 3,
            'data': {'fromSeq': 1, 'count': 2, 'bytes': 10},
          },
        });
        socket.item(id, historyFrame(4));
      };
      final sub = client
          .watch('s', options: const WatchOptions(resultOnly: true, includeSyncEvents: true, includeHostEvents: false))
          .listen((event) {
            events.add(event);
            if (event is SessionLogEvent && event.seq == 4 && !sawTail.isCompleted) sawTail.complete();
          }, onError: errors.add);
      await sawTail.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(opened, hasLength(1));
      expect(errors, isEmpty);
      expect(events.whereType<SessionOmittedEvent>().single.count, 2);
      expect(events.whereType<SessionLogEvent>().map((event) => event.seq), containsAll([3, 4]));
      await sub.cancel();
    } finally {
      await client.close();
      await host.close();
    }
  });
}
