import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

/// Unified image selection for EMIS mobile and Windows desktop.
/// On desktop, both the gallery and camera actions open the native file picker:
/// image_picker camera capture is not implemented by the Windows plugin.
Future<XFile?> pickEmisImage(
  {required ImageSource source,
  int imageQuality = 90,
  double? maxWidth,
  double? maxHeight,
}) async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    final files = result?.files ?? const <PlatformFile>[];
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || path.isEmpty) return null;
    return XFile(path);
  }

  return ImagePicker().pickImage(
    source: source,
    imageQuality: imageQuality,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
}

/// Multi-image selection used by batch photo workflows.
Future<List<XFile>> pickEmisImages({int imageQuality = 90}) async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: false,
    );
    return (result?.files ?? const <PlatformFile>[])
        .where((file) => file.path != null && file.path!.isNotEmpty)
        .map((file) => XFile(file.path!))
        .toList(growable: false);
  }
  return ImagePicker().pickMultiImage(imageQuality: imageQuality);
}
