import 'dart:typed_data';

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/tone_synth.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal WAV reader, so the tests verify the bytes actually written rather
/// than trusting the writer's own bookkeeping.
class _Wav {
  _Wav(Uint8List bytes) : _d = ByteData.sublistView(bytes) {
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    riffSize = _d.getUint32(4, Endian.little);
    declaredTotal = bytes.length;

    // Walk the chunk list rather than assuming a fixed 44-byte header.
    var p = 12;
    while (p + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(p, p + 4));
      final size = _d.getUint32(p + 4, Endian.little);
      if (id == 'fmt ') {
        fmtSize = size;
        audioFormat = _d.getUint16(p + 8, Endian.little);
        channels = _d.getUint16(p + 10, Endian.little);
        sampleRate = _d.getUint32(p + 12, Endian.little);
        byteRate = _d.getUint32(p + 16, Endian.little);
        blockAlign = _d.getUint16(p + 20, Endian.little);
        bitsPerSample = _d.getUint16(p + 22, Endian.little);
      } else if (id == 'data') {
        dataOffset = p + 8;
        dataSize = size;
      } else if (id == 'fact') {
        factFrames = _d.getUint32(p + 8, Endian.little);
      }
      p += 8 + size + (size.isOdd ? 1 : 0);
    }
    expect(dataOffset, isNotNull, reason: 'no data chunk found');
  }

  final ByteData _d;
  late final int riffSize;
  late final int declaredTotal;
  int? fmtSize, audioFormat, channels, sampleRate, byteRate, blockAlign, bitsPerSample;
  int? dataOffset, dataSize, factFrames;

  int get frames => dataSize! ~/ blockAlign!;

  double sample(int frame, int channel) {
    final off = dataOffset! + (frame * channels! + channel) * (bitsPerSample! ~/ 8);
    return audioFormat == 3
        ? _d.getFloat32(off, Endian.little)
        : _d.getInt16(off, Endian.little) / 32767.0;
  }

  double peak(int channel) {
    var m = 0.0;
    for (var i = 0; i < frames; i++) {
      final v = sample(i, channel).abs();
      if (v > m) m = v;
    }
    return m;
  }
}

void main() {
  const synth = ToneSynth();

  group('WAV container', () {
    test('float32 header is self-consistent', () {
      final w = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: 0.5,
        ear: Ear.right,
      ));

      expect(w.audioFormat, 3, reason: '3 = IEEE float');
      expect(w.channels, 2, reason: 'stereo is required for per-ear routing');
      expect(w.sampleRate, 44100);
      expect(w.bitsPerSample, 32);
      expect(w.blockAlign, 8); // 2 ch * 4 bytes
      expect(w.byteRate, 44100 * 8);
      expect(w.fmtSize, 18, reason: 'non-PCM formats need cbSize');
      expect(w.factFrames, w.frames, reason: 'fact chunk must match the data');
      expect(w.riffSize, w.declaredTotal - 8);
    });

    test('int16 header is self-consistent', () {
      final w = _Wav(const ToneSynth(format: PcmFormat.int16).tone(
        frequencyHz: 1000,
        amplitude: 0.5,
        ear: Ear.right,
      ));

      expect(w.audioFormat, 1, reason: '1 = PCM');
      expect(w.bitsPerSample, 16);
      expect(w.blockAlign, 4);
      expect(w.fmtSize, 16);
      expect(w.riffSize, w.declaredTotal - 8);
    });

    test('duration determines the frame count', () {
      final w = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: 0.5,
        ear: Ear.left,
        duration: const Duration(milliseconds: 500),
      ));
      expect(w.frames, 22050); // 0.5 s at 44.1 kHz
    });
  });

  group('per-ear channel isolation', () {
    // This is the property the whole per-ear test design rests on: if signal
    // leaked into the other channel, every reading would be of the better ear.
    test('a right-ear tone is silent in the left channel', () {
      final w = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: 0.8,
        ear: Ear.right,
      ));
      expect(w.peak(1), greaterThan(0.5), reason: 'right channel carries it');
      expect(w.peak(0), 0.0, reason: 'left channel must be digitally silent');
    });

    test('a left-ear tone is silent in the right channel', () {
      final w = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: 0.8,
        ear: Ear.left,
      ));
      expect(w.peak(0), greaterThan(0.5));
      expect(w.peak(1), 0.0);
    });

    test('silence is silent in both channels', () {
      final w = _Wav(synth.silence());
      expect(w.peak(0), 0.0);
      expect(w.peak(1), 0.0);
      expect(w.frames, greaterThan(0), reason: 'must still occupy real time');
    });
  });

  group('signal quality', () {
    test('peak amplitude tracks the requested amplitude', () {
      for (final a in [1.0, 0.5, 0.1, 0.001]) {
        final w = _Wav(synth.tone(
          frequencyHz: 1000,
          amplitude: a,
          ear: Ear.right,
        ));
        expect(w.peak(1), closeTo(a, a * 0.02));
      }
    });

    test('float32 preserves near-threshold amplitudes that int16 destroys', () {
      // ~-100 dBFS, the level a 0 dB HL tone sits at.
      const tiny = 1e-5;
      final f = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: tiny,
        ear: Ear.right,
      ));
      final i = _Wav(const ToneSynth(format: PcmFormat.int16).tone(
        frequencyHz: 1000,
        amplitude: tiny,
        ear: Ear.right,
      ));

      expect(f.peak(1), closeTo(tiny, tiny * 0.05));
      expect(i.peak(1), 0.0,
          reason: '16-bit quantises this to silence - the documented reason '
              'float32 is the default');
    });

    test('the tone starts and ends at zero (no click)', () {
      final w = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: 1.0,
        ear: Ear.right,
      ));
      expect(w.sample(0, 1).abs(), lessThan(1e-6));
      expect(w.sample(w.frames - 1, 1).abs(), lessThan(1e-3));
    });

    test('the ramp rises monotonically over its window', () {
      final w = _Wav(synth.tone(
        frequencyHz: 50, // low frequency: envelope dominates the waveform
        amplitude: 1.0,
        ear: Ear.right,
        ramp: const Duration(milliseconds: 100),
      ));
      // Compare envelope peaks in successive 10 ms slices of the ramp.
      double sliceMax(int fromMs, int toMs) {
        var m = 0.0;
        for (var i = fromMs * 44100 ~/ 1000; i < toMs * 44100 ~/ 1000; i++) {
          final v = w.sample(i, 1).abs();
          if (v > m) m = v;
        }
        return m;
      }

      expect(sliceMax(0, 20), lessThan(sliceMax(40, 60)));
      expect(sliceMax(40, 60), lessThan(sliceMax(80, 100)));
    });

    test('a ramp longer than the tone does not overrun', () {
      final w = _Wav(synth.tone(
        frequencyHz: 1000,
        amplitude: 1.0,
        ear: Ear.right,
        duration: const Duration(milliseconds: 20),
        ramp: const Duration(milliseconds: 500),
      ));
      expect(w.frames, 882);
      expect(w.peak(1), greaterThan(0.0));
      expect(w.peak(1), lessThanOrEqualTo(1.0));
    });
  });
}
