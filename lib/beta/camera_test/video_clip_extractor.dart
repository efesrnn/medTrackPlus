library;

import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:medTrackPlus/beta/camera_test/camera_stream_manager.dart';
import 'package:medTrackPlus/beta/verification/accuracy_scoring_engine.dart';


class CriticalMoment {
  final String label;
  final DateTime timestamp;
  final List<BufferedFrame> frames;

  const CriticalMoment({
    required this.label,
    required this.timestamp,
    required this.frames,
  });

  int get frameCount => frames.length;
}


class VideoClipExtractor {
  final double windowSeconds;

  /// Ring buffer duration in seconds.
  static const int bufferDurationSeconds = 15;

  VideoClipExtractor({this.windowSeconds = 2.0});

  /// Extracts a clip only if the classification is [suspicious].
  /// Returns the file path of the written clip, or null if skipped.
  Future<String?> extractIfSuspicious({
    required VerificationResult classification,
    required VideoFrameBuffer buffer,
    required List<DateTime> criticalTimestamps,
    required List<String> criticalLabels,
  }) async {
    if (classification != VerificationResult.suspicious) return null;
    if (buffer.isEmpty) return null;

    final moments = markCriticalMoments(
      buffer: buffer,
      timestamps: criticalTimestamps,
      labels: criticalLabels,
    );

    final clipFrames = combineMoments(moments, buffer);
    if (clipFrames.isEmpty) return null;

    return writeClip(clipFrames);
  }

  /// Finds frames around each critical timestamp within the buffer.
  List<CriticalMoment> markCriticalMoments({
    required VideoFrameBuffer buffer,
    required List<DateTime> timestamps,
    required List<String> labels,
  }) {
    final frames = buffer.frames;
    if (frames.isEmpty || timestamps.isEmpty) return [];

    final halfWindow = Duration(
      milliseconds: (windowSeconds * 500).round(),
    );

    final moments = <CriticalMoment>[];

    for (int i = 0; i < timestamps.length; i++) {
      final ts = timestamps[i];
      final label = i < labels.length ? labels[i] : 'moment_$i';

      final windowStart = ts.subtract(halfWindow);
      final windowEnd = ts.add(halfWindow);

      final windowFrames = frames.where((f) =>
        f.timestamp.isAfter(windowStart) &&
        f.timestamp.isBefore(windowEnd),
      ).toList();

      if (windowFrames.isNotEmpty) {
        moments.add(CriticalMoment(
          label: label,
          timestamp: ts,
          frames: windowFrames,
        ));
      }
    }

    return moments;
  }


  List<BufferedFrame> combineMoments(
    List<CriticalMoment> moments,
    VideoFrameBuffer buffer,
  ) {
    if (moments.isEmpty) return [];

    final seen = <DateTime>{};
    final combined = <BufferedFrame>[];

    // Sort moments chronologically.
    final sorted = List<CriticalMoment>.from(moments)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    for (final moment in sorted) {
      for (final frame in moment.frames) {
        if (seen.add(frame.timestamp)) {
          combined.add(frame);
        }
      }
    }

    return combined;
  }


  Future<String> writeClip(List<BufferedFrame> frames) async {
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/suspicious_clip_$timestamp.raw');

    final sink = file.openWrite();

    for (final frame in frames) {
      // 4-byte little-endian header per frame
      sink.add(_int32Bytes(frame.width));
      sink.add(_int32Bytes(frame.height));
      sink.add(_int32Bytes(frame.yPlane.length));
      sink.add(frame.yPlane);
    }

    await sink.flush();
    await sink.close();

    return file.path;
  }

  Uint8List _int32Bytes(int value) {
    return Uint8List(4)
      ..buffer.asByteData().setInt32(0, value, Endian.little);
  }
}
