import 'package:flutter_test/flutter_test.dart';
import 'package:giki/sync/serving_origin.dart';

void main() {
  test('the server defaults to the origin the app was loaded from', () {
    expect(
      servingOrigin(Uri.parse('https://giki.example.org/some/deep/link?x=1')),
      'https://giki.example.org',
    );
    expect(
      servingOrigin(Uri.parse('http://localhost:8110/')),
      'http://localhost:8110',
    );
  });

  test('no default when the app was not loaded from a web server', () {
    expect(servingOrigin(Uri.parse('file:///home/me/giki/')), '');
  });
}
