import 'dart:math' as math;
import 'dart:typed_data';

import 'audiometry.dart';

/// Sample format for the generated WAV.
enum PcmFormat {
  /// 32-bit IEEE float. The default, and the reason quiet tones work at all.
  ///
  /// Near-threshold tones sit around -90 dBFS. In 16-bit PCM that is under one
  /// least-significant bit - the tone would quantise to silence or to a burst
  /// of distortion. Float32 has the dynamic range to represent it cleanly.
  float32,

  /// 16-bit signed PCM. Maximum device compatibility, but the bottom ~20 dB of
  /// the range is lost to quantisation. Use only if float32 will not play.
  int16,
}

/// Builds pure-tone stimuli as in-memory WAV files.
///
/// Deliberately dependency-free (no Flutter, no plugins, no I/O) so the signal
/// generation can be unit tested directly.
class ToneSynth {
  const ToneSynth({
    this.sampleRate = 44100,
    this.format = PcmFormat.float32,
  });

  final int sampleRate;
  final PcmFormat format;

  /// Synthesises a stereo WAV containing a pure tone in one ear only.
  ///
  /// [amplitude] is linear (0.0-1.0) and comes from
  /// [CalibrationProfile.amplitudeFor] - this class does no dB conversion.
  ///
  /// The opposite channel is filled with digital silence. That channel
  /// separation is what makes per-ear testing possible: with headphones on, a
  /// tone written only to the right channel is heard only by the right ear.
  Uint8List tone({
    required double frequencyHz,
    required double amplitude,
    required Ear ear,
    Duration duration = kToneDuration,
    Duration ramp = kToneRampDuration,
  }) {
    assert(frequencyHz > 0);
    assert(amplitude >= 0 && amplitude <= 1);

    final frameCount = (duration.inMicroseconds * sampleRate / 1e6).round();
    final samples = Float64List(frameCount);

    final twoPiFOverFs = 2 * math.pi * frequencyHz / sampleRate;
    for (var i = 0; i < frameCount; i++) {
      samples[i] = amplitude * math.sin(twoPiFOverFs * i);
    }

    _applyRaisedCosineRamp(samples, ramp);
    return _encodeStereo(samples, signalChannel: ear == Ear.left ? 0 : 1);
  }

  /// A silent stimulus of the same duration as a tone, for catch trials.
  Uint8List silence({Duration duration = kToneDuration}) {
    final frameCount = (duration.inMicroseconds * sampleRate / 1e6).round();
    return _encodeStereo(Float64List(frameCount), signalChannel: null);
  }

  /// Applies a raised-cosine (Hann) onset and offset envelope in place.
  ///
  /// Switching a tone on abruptly produces a click whose energy is spread
  /// across the spectrum. A patient can hear that click even when the tone
  /// itself is below their threshold, so every reading would come out falsely
  /// good. ISO 389 requires a gradual onset for exactly this reason.
  void _applyRaisedCosineRamp(Float64List samples, Duration ramp) {
    final n = samples.length;
    if (n == 0) return;

    var rampSamples = (ramp.inMicroseconds * sampleRate / 1e6).round();
    // A ramp longer than half the tone would leave no steady-state portion.
    if (rampSamples * 2 > n) rampSamples = n ~/ 2;
    if (rampSamples <= 0) return;

    for (var i = 0; i < rampSamples; i++) {
      final gain = 0.5 * (1 - math.cos(math.pi * i / rampSamples));
      samples[i] *= gain;
      samples[n - 1 - i] *= gain;
    }
  }

  /// Interleaves [mono] into a 2-channel WAV, routing it to [signalChannel]
  /// (0 = left, 1 = right). A null channel produces silence in both.
  Uint8List _encodeStereo(Float64List mono, {required int? signalChannel}) {
    const channels = 2;
    final frames = mono.length;
    final bytesPerSample = format == PcmFormat.float32 ? 4 : 2;
    final dataSize = frames * channels * bytesPerSample;

    final isFloat = format == PcmFormat.float32;
    final fmtChunkSize = isFloat ? 18 : 16;
    // RIFF size covers everything after the size field itself.
    final riffSize = 4 // "WAVE"
        +
        (8 + fmtChunkSize) +
        (isFloat ? 12 : 0) // optional "fact" chunk
        +
        (8 + dataSize);

    final out = BytesBuilder(copy: false);

    void ascii(String s) => out.add(s.codeUnits);
    void u32(int v) {
      final b = ByteData(4)..setUint32(0, v, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    void u16(int v) {
      final b = ByteData(2)..setUint16(0, v, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    ascii('RIFF');
    u32(riffSize);
    ascii('WAVE');

    ascii('fmt ');
    u32(fmtChunkSize);
    u16(isFloat ? 3 : 1); // 3 = IEEE float, 1 = PCM
    u16(channels);
    u32(sampleRate);
    u32(sampleRate * channels * bytesPerSample); // byte rate
    u16(channels * bytesPerSample); // block align
    u16(bytesPerSample * 8); // bits per sample
    if (isFloat) u16(0); // cbSize - required when audioFormat != 1

    if (isFloat) {
      // A "fact" chunk carrying the sample count is mandatory for non-PCM
      // formats; some decoders reject float WAVs without it.
      ascii('fact');
      u32(4);
      u32(frames);
    }

    ascii('data');
    u32(dataSize);

    final payload = ByteData(dataSize);
    var offset = 0;
    for (var i = 0; i < frames; i++) {
      for (var ch = 0; ch < channels; ch++) {
        final v = ch == signalChannel ? mono[i] : 0.0;
        if (isFloat) {
          payload.setFloat32(offset, v, Endian.little);
          offset += 4;
        } else {
          // Scale to full-scale 16-bit and clamp; 32767 rather than 32768 so
          // +1.0 does not wrap to the most-negative value.
          final s = (v * 32767).round().clamp(-32768, 32767);
          payload.setInt16(offset, s, Endian.little);
          offset += 2;
        }
      }
    }
    out.add(payload.buffer.asUint8List());

    return out.takeBytes();
  }
}
