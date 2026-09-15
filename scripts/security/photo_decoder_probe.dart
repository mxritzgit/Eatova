// Manual Android fixture; never use this target for a distributed build.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/services/meal_photo_compressor.dart';
import 'package:eatova/src/services/photo_container.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

const _cases = <(String, int, int, bool)>[
  ('picker-jpeg', 1600, 1200, false),
  ('camera-12mp-jpeg', 4000, 3000, false),
  ('rgba-png', 2048, 2048, true),
  ('raster-boundary-rgba-png', 4096, 4096, true),
];

Uint8List _fixture((String, int, int, bool) spec) {
  final (_, width, height, png) = spec;
  final pixels = img.Image(width: width, height: height, numChannels: 4);
  // Synthetic gradients, not private photos or adversarial compressed streams.
  for (final pixel in pixels) {
    pixel.setRgba(pixel.x & 255, pixel.y & 255, (pixel.x + pixel.y) & 255, 255);
  }
  return Uint8List.fromList(
    png ? img.encodePng(pixels) : img.encodeJpg(pixels, quality: 90),
  );
}

int _cpuTicks() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  // Fields 14/15 are process user/system ticks; the trimmed list starts at 3.
  return int.parse(fields[11]) + int.parse(fields[12]);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid ||
      kReleaseMode ||
      !const bool.fromEnvironment('PHOTO_DECODER_PROBE') ||
      const String.fromEnvironment('SUPABASE_URL') != 'https://ci.invalid' ||
      const String.fromEnvironment('SUPABASE_ANON_KEY') != 'ci-dummy-key') {
    throw StateError(
      'Isolated Android debug/profile and dummy defines required',
    );
  }
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Synthetic photo decoder probe')),
      ),
    ),
  );
  // No Supabase, Sentry, camera, gallery, account or network initialization.
  final directory = await getApplicationSupportDirectory();
  final reportFile = File('${directory.path}/photo-decoder-probe.json');
  final report = await reportFile.exists()
      ? (jsonDecode(await reportFile.readAsString()) as Map)
            .cast<String, dynamic>()
      : <String, dynamic>{
          'next_phase': 0,
          'mode': kProfileMode ? 'profile' : 'debug',
          'platform': Platform.operatingSystemVersion,
          'sample_period_ms': 25,
          'raster_budget_bytes': maxPhotoRasterBytes,
          'results': <dynamic>[],
        };
  Future<void> save() async =>
      reportFile.writeAsString(jsonEncode(report), flush: true);
  try {
    final phase = report['next_phase'] as int;
    if (phase == 0) {
      // Fixture generation is a separate process launch, outside measurements.
      for (final spec in _cases) {
        final bytes = await compute(_fixture, spec);
        await File('${directory.path}/${spec.$1}.fixture').writeAsBytes(bytes);
      }
      report['next_phase'] = 1;
      report['state'] = 'fixtures_ready_restart_process';
      await save();
      return;
    }
    if (phase > _cases.length) return;
    final spec = _cases[phase - 1];
    final input = await File(
      '${directory.path}/${spec.$1}.fixture',
    ).readAsBytes();
    report['state'] = 'running';
    report['active_case'] = spec.$1;
    await save();
    // The host force-stops between phases. No previous image decode remains.
    final baselineRss = ProcessInfo.currentRss;
    var sampledPeakRss = baselineRss;
    var samples = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > sampledPeakRss) sampledPeakRss = rss;
      samples++;
    });
    final ticksBefore = _cpuTicks();
    final watch = Stopwatch()..start();
    final Uint8List output;
    try {
      output = await compute(compressMealPhoto, input);
    } finally {
      watch.stop();
      timer.cancel();
    }
    final cpuTicks = _cpuTicks() - ticksBefore;
    final processHighWaterRss = ProcessInfo.maxRss;
    final rssAfter = ProcessInfo.currentRss;
    if (rssAfter > sampledPeakRss) sampledPeakRss = rssAfter;
    final normalized = inspectPhotoContainer(output);
    final expectedWidth = spec.$2 >= spec.$3
        ? 1600
        : (1600 * spec.$2 ~/ spec.$3);
    final expectedHeight = spec.$3 >= spec.$2
        ? 1600
        : (1600 * spec.$3 ~/ spec.$2);
    if (normalized.mime != 'image/jpeg' ||
        normalized.width != expectedWidth ||
        normalized.height != expectedHeight) {
      throw StateError('Unexpected normalized dimensions');
    }
    (report['results'] as List).add({
      'case': spec.$1,
      'source_width': spec.$2,
      'source_height': spec.$3,
      'input_bytes': input.length,
      'output_bytes': output.length,
      'output_width': normalized.width,
      'output_height': normalized.height,
      'wall_ms': watch.elapsedMilliseconds,
      'process_cpu_ticks': cpuTicks,
      'rss_before_bytes': baselineRss,
      'rss_after_bytes': rssAfter,
      'sampled_peak_rss_bytes': sampledPeakRss,
      'process_high_water_rss_bytes': processHighWaterRss,
      'rss_samples': samples,
      'passed': true,
    });
    report['next_phase'] = phase + 1;
    report['state'] = phase == _cases.length
        ? 'complete'
        : 'case_complete_restart_process';
    report.remove('active_case');
    await save();
  } catch (error) {
    report['state'] = 'failed';
    report['error_type'] = error.runtimeType.toString();
    await save();
    rethrow;
  }
}
