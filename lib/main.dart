import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/services/armin_app_state.dart';
import 'features/tasks/services/scheduled_task_wake_service.dart';
import 'features/tasks/services/system_calendar_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await const NativeScheduledTaskWakeService().initialize();
  runApp(ArminApp(state: ArminAppState.run()));
}

@pragma('vm:entry-point')
Future<void> arminBackgroundSchedulerMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final state = ArminAppState.run(
    scheduledTaskWakeService: const NoopScheduledTaskWakeService(),
    systemCalendarService: const NoopSystemCalendarService(),
  );
  await state.load();
  await state.processDueScheduledTasks();
  await Future<void>.delayed(const Duration(seconds: 20));
  state.dispose();
}
