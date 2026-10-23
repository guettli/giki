import 'package:flutter_test/flutter_test.dart';
import 'package:giki/sync/api_client.dart';

void main() {
  test('parses a sync response', () {
    const body = '''
{
  "cursor": 7,
  "results": [
    {"client_seq": 1, "record_id": "n1", "status": "applied", "seq": 7},
    {"client_seq": 2, "record_id": "n2", "status": "stale", "reason": "stored version is newer"}
  ],
  "changes": [
    {"seq": 7, "table": "nodes", "record_id": "n1", "op": "UPDATE",
     "updated_at": "2026-10-23T10:00:00.000Z",
     "payload": {"id": "n1", "title": "Leitner", "is_deleted": 0},
     "actor_user_id": "bob", "origin_device_id": "laptop-b",
     "applied_at": "2026-10-23T10:00:01.000Z"}
  ],
  "has_more": false,
  "server_time": "2026-10-23T10:00:02.000Z"
}
''';
    final response = parseSyncResponse(body);
    expect(response.cursor, 7);
    expect(response.hasMore, isFalse);
    expect(response.results, hasLength(2));
    expect(response.results[0].applied, isTrue);
    expect(response.results[1].stale, isTrue);
    expect(response.results[1].reason, 'stored version is newer');
    expect(response.changes, hasLength(1));
    expect(response.changes.single.payload['title'], 'Leitner');
  });

  test('tolerates a response without optional fields', () {
    final response = parseSyncResponse('{"cursor": 0}');
    expect(response.cursor, 0);
    expect(response.results, isEmpty);
    expect(response.changes, isEmpty);
    expect(response.hasMore, isFalse);
  });
}
