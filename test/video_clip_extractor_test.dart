vidimport 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:medTrackPlus/beta/camera_test/camera_stream_manager.dart';
import 'package:medTrackPlus/beta/camera_test/video_clip_extractor.dart';
import 'package:medTrackPlus/beta/verification/accuracy_scoring_engine.dart';

/// Helper: create a buffer with frames spanning [seconds] at ~10fps.
VideoFrameBuffer _buildBuffer(int seconds) {
  final buffer = VideoFrameBuffer(maxFrames: seconds * 10);
  final start = DateTime(2026, 1, 1, 0, 0, 0);

  for (int i = 0; i < seconds * 10; i++) {
    buffer.add(BufferedFrame(
      yPlane: Uint8List.fromList([i % 256]),
      width: 320,
      height: 240,
      timestamp: start.add(Duration(milliseconds: i * 100)),
    ));
  }
  return buffer;
}

DateTime _ts(int seconds) => DateTime(2026, 1, 1, 0, 0, seconds);

void main() {
  // ---------------------------------------------------------------------------
  // Ring buffer 15 seconds
  // ---------------------------------------------------------------------------
  group('Ring buffer 15 seconds', () {
    test('holds ~15 seconds of frames at 10fps', () {
      final buffer = VideoFrameBuffer(maxFrames: 150); // 15s * 10fps
      final start = DateTime(2026, 1, 1);

      for (int i = 0; i < 200; i++) {
        buffer.add(BufferedFrame(
          yPlane: Uint8List.fromList([i % 256]),
          width: 320,
          height: 240,
          timestamp: start.add(Duration(milliseconds: i * 100)),
        ));
      }

      expect(buffer.length, 150);
      // Oldest frame should be at 5s (200-150=50th frame = 5000ms)
      final oldest = buffer.frames.first.timestamp;
      final newest = buffer.frames.last.timestamp;
      final duration = newest.difference(oldest);
      expect(duration.inSeconds, 14); // ~15s window (149 gaps of 100ms)
    });
  });

  // ---------------------------------------------------------------------------
  // Extract critical moments
  // ---------------------------------------------------------------------------
  group('Extract critical moments', () {
    test('finds frames around critical timestamps', () {
      final buffer = _buildBuffer(15);
      final extractor = VideoClipExtractor(windowSeconds: 2.0);

      final moments = extractor.markCriticalMoments(
        buffer: buffer,
        timestamps: [_ts(5)],
        labels: ['pillDetected'],
      );

      expect(moments.length, 1);
      expect(moments[0].label, 'pillDetected');
      expect(moments[0].frames.isNotEmpty, true);

      // All frames should be within ±1s of ts(5)
      for (final f in moments[0].frames) {
        final diff = f.timestamp.difference(_ts(5)).inMilliseconds.abs();
        expect(diff, lessThanOrEqualTo(1000));
      }
    });

    test('multiple critical moments extracted separately', () {
      final buffer = _buildBuffer(15);
      final extractor = VideoClipExtractor(windowSeconds: 2.0);

      final moments = extractor.markCriticalMoments(
        buffer: buffer,
        timestamps: [_ts(3), _ts(8), _ts(12)],
        labels: ['pillDetected', 'pillConsumed', 'mouthVerified'],
      );

      expect(moments.length, 3);
      expect(moments[0].label, 'pillDetected');
      expect(moments[1].label, 'pillConsumed');
      expect(moments[2].label, 'mouthVerified');
    });

    test('returns empty if timestamp outside buffer range', () {
      final buffer = _buildBuffer(15);
      final extractor = VideoClipExtractor(windowSeconds: 2.0);

      final moments = extractor.markCriticalMoments(
        buffer: buffer,
        timestamps: [_ts(60)], // way outside buffer
        labels: ['missed'],
      );

      expect(moments.length, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // Combine into clip
  // ---------------------------------------------------------------------------
  group('Combine into clip', () {
    test('combines moments chronologically without duplicates', () {
      final buffer = _buildBuffer(15);
      final extractor = VideoClipExtractor(windowSeconds: 2.0);

      final moments = extractor.markCriticalMoments(
        buffer: buffer,
        timestamps: [_ts(5), _ts(10)],
        labels: ['a', 'b'],
      );

      final combined = extractor.combineMoments(moments, buffer);

      // Should be sorted chronologically
      for (int i = 1; i < combined.length; i++) {
        expect(
          combined[i].timestamp.isAfter(combined[i - 1].timestamp) ||
              combined[i].timestamp == combined[i - 1].timestamp,
          true,
        );
      }

      // No duplicate timestamps
      final timestamps = combined.map((f) => f.timestamp).toSet();
      expect(timestamps.length, combined.length);
    });

    test('overlapping windows produce no duplicate frames', () {
      final buffer = _buildBuffer(15);
      // Large window so moments at 5s and 6s overlap
      final extractor = VideoClipExtractor(windowSeconds: 4.0);

      final moments = extractor.markCriticalMoments(
        buffer: buffer,
        timestamps: [_ts(5), _ts(6)],
        labels: ['a', 'b'],
      );

      final combined = extractor.combineMoments(moments, buffer);
      final timestamps = combined.map((f) => f.timestamp).toList();
      final unique = timestamps.toSet();
      expect(unique.length, timestamps.length);
    });
  });

  // ---------------------------------------------------------------------------
  // Only for suspicious classification
  // ---------------------------------------------------------------------------
  group('Only for suspicious classification', () {
    test('returns null for success classification', () async {
      final buffer = _buildBuffer(15);
      final extractor = VideoClipExtractor();

      final result = await extractor.extractIfSuspicious(
        classification: VerificationResult.success,
        buffer: buffer,
        criticalTimestamps: [_ts(5)],
        criticalLabels: ['pill'],
      );

      expect(result, isNull);
    });

    test('returns null for rejected classification', () async {
      final buffer = _buildBuffer(15);
      final extractor = VideoClipExtractor();

      final result = await extractor.extractIfSuspicious(
        classification: VerificationResult.rejected,
        buffer: buffer,
        criticalTimestamps: [_ts(5)],
        criticalLabels: ['pill'],
      );

      expect(result, isNull);
    });

    test('returns null for suspicious with empty buffer', () async {
      final buffer = VideoFrameBuffer();
      final extractor = VideoClipExtractor();

      final result = await extractor.extractIfSuspicious(
        classification: VerificationResult.suspicious,
        buffer: buffer,
        criticalTimestamps: [_ts(5)],
        criticalLabels: ['pill'],
      );

      expect(result, isNull);
    });
  });
}
