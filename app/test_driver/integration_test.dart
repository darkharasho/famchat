// ignore_for_file: avoid_print
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        for (final line in (data?['spike'] as List? ?? const [])) {
          print(line);
        }
      },
    );
