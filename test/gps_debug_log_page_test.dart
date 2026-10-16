import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_spark/core/gps_debug_logger.dart';
import 'package:mimo_spark/ui/gps_debug_log_page.dart';

void main() {
  testWidgets('GPS diagnostic identifies source and stops polling on exit', (tester) async {
    GpsDebugLogger.enabled = false;
    await tester.pumpWidget(const MaterialApp(home: GpsDebugLogPage()));
    expect(find.text('Version source : ${GpsDebugLogger.buildSha}'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    // The widget-test binding also rejects periodic timers left alive at exit.
  });
}
