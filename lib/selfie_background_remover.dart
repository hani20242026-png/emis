import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// أداة إزالة خلفية الصور المتوافقة مع Windows (.exe) عبر معالجة البكسلات وحواف الخلفية محلياً[span_2](start_span)[span_2](end_span)[span_3](start_span)[span_3](end_span).
class SelfieBackgroundRemover {
  SelfieBackgroundRemover._();

  static Future<File?> removeBackground(File imageFile) async {
    if (!await imageFile.exists()) return null;

    final bytes = await imageFile.readAsBytes();
    var source = img.decodeImage(bytes);
    if (source == null) return null;

    source = img.bakeOrientation(source);

    const maxDimension = 512;
    if (source.width > maxDimension || source.height > maxDimension) {
      source = img.copyResize(
        source,
        width: source.width >= source.height ? maxDimension : null,
        height: source.height > source.width ? maxDimension : null,
        interpolation: img.Interpolation.linear,
      );
    }

    // تقدير لون الخلفية من حواف الصورة الخارجية
    final bgSamples = <img.Pixel>[];
    for (var x = 0; x < source.width; x++) {
      bgSamples.add(source.getPixel(x, 0));
      bgSamples.add(source.getPixel(x, source.height - 1));
    }
    for (var y = 0; y < source.height; y++) {
      bgSamples.add(source.getPixel(0, y));
      bgSamples.add(source.getPixel(source.width - 1, y));
    }

    double sumR = 0, sumG = 0, sumB = 0;
    for (final p in bgSamples) {
      sumR += p.r;
      sumG += p.g;
      sumB += p.b;
    }
    final count = bgSamples.isEmpty ? 1 : bgSamples.length;
    final bgR = sumR / count;
    final bgG = sumG / count;
    final bgB = sumB / count;

    final result = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 4,
    );

    const threshold = 48.0;
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final pixel = source.getPixel(x, y);
        final dr = pixel.r - bgR;
        final dg = pixel.g - bgG;
        final db = pixel.b - bgB;
        final dist = math.sqrt(dr * dr + dg * dg + db * db);

        int alpha = 255;
        if (dist < threshold) {
          alpha = ((dist / threshold) * 255.0).round().clamp(0, 255);
        }
        result.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, alpha);
      }
    }

    final output = File(
      '${imageFile.path}_win_nobg_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await output.writeAsBytes(img.encodePng(result, level: 6), flush: true);
    return output;
  }

  static void dispose() {}
}
