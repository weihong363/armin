import 'package:flutter/widgets.dart';

import 'core/services/armin_app_state.dart';

class AppStateScope extends InheritedNotifier<ArminAppState> {
  const AppStateScope({
    required ArminAppState state,
    required super.child,
    super.key,
  }) : super(notifier: state);

  static ArminAppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found in widget tree.');
    return scope!.notifier!;
  }
}
