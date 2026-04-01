import 'package:flutter/foundation.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';

/// Global singleton — access via [modeProvider].
/// Follows the same pattern as [globalAlarmState] in main.dart.
///
/// Usage (listen to changes):
///   ValueListenableBuilder<AppMode>(
///     valueListenable: modeProvider,
///     builder: (context, mode, _) { ... },
///   )
///
/// Usage (read / write):
///   modeProvider.value = AppMode.deviceFree;
final modeProvider = ModeProvider();

class ModeProvider extends ChangeNotifier implements ValueListenable<AppMode> {
  AppMode _mode = AppMode.device;

  @override
  AppMode get value => _mode;

  void setMode(AppMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }

  bool get isDeviceFree => _mode == AppMode.deviceFree;
  bool get isDevice => _mode == AppMode.device;
}
