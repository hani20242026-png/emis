import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Requests microphone access on mobile platforms. Desktop speech plugins use
/// the operating system's own microphone privacy prompt, so permission_handler
/// must not be queried on Windows/macOS/Linux.
Future<bool> ensureEmisMicrophonePermission() async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return true;
  }

  final current = await Permission.microphone.status;
  if (current.isGranted) return true;
  final requested = await Permission.microphone.request();
  return requested.isGranted;
}
