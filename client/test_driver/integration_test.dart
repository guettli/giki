// Host side of the end-to-end test. `flutter drive` runs this on the machine
// while integration_test/ runs inside the browser.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
