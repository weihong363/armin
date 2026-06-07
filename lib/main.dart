import 'package:flutter/material.dart';

import 'app.dart';
import 'core/services/armin_app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ArminApp(state: ArminAppState.run()));
}
