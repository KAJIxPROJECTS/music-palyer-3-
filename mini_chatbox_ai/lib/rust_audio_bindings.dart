import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef PlayerCreateC = ffi.Pointer<ffi.Void> Function();
typedef PlayerCreateDart = ffi.Pointer<ffi.Void> Function();

typedef PlayerDestroyC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef PlayerDestroyDart = void Function(ffi.Pointer<ffi.Void>);

typedef PlayerLoadC = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef PlayerLoadDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);

typedef PlayerPlayC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef PlayerPlayDart = void Function(ffi.Pointer<ffi.Void>);

typedef PlayerPauseC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef PlayerPauseDart = void Function(ffi.Pointer<ffi.Void>);

typedef PlayerStopC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef PlayerStopDart = void Function(ffi.Pointer<ffi.Void>);

typedef PlayerSeekC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSeekDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerGetPositionC = ffi.Uint32 Function(ffi.Pointer<ffi.Void>);
typedef PlayerGetPositionDart = int Function(ffi.Pointer<ffi.Void>);

typedef PlayerGetDurationC = ffi.Uint32 Function(ffi.Pointer<ffi.Void>);
typedef PlayerGetDurationDart = int Function(ffi.Pointer<ffi.Void>);

typedef PlayerIsPlayingC = ffi.Bool Function(ffi.Pointer<ffi.Void>);
typedef PlayerIsPlayingDart = bool Function(ffi.Pointer<ffi.Void>);

typedef PlayerGetDeviceNameC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef PlayerGetDeviceNameDart = int Function(ffi.Pointer<ffi.Uint8>, int);

typedef PlayerGetDeviceSampleRateC = ffi.Int32 Function();
typedef PlayerGetDeviceSampleRateDart = int Function();

typedef PlayerGetDeviceChannelsC = ffi.Int32 Function();
typedef PlayerGetDeviceChannelsDart = int Function();

typedef PlayerSetPreampC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetPreampDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerSetEqBandC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef PlayerSetEqBandDart = void Function(ffi.Pointer<ffi.Void>, int, double);

typedef PlayerSetStereoExpansionC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetStereoExpansionDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerSetStereoPanC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetStereoPanDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerSetReverbRoomSizeC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetReverbRoomSizeDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerSetReverbMixC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetReverbMixDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerSetLimiterEnabledC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Bool);
typedef PlayerSetLimiterEnabledDart = void Function(ffi.Pointer<ffi.Void>, bool);

typedef PlayerSetLimiterThresholdC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetLimiterThresholdDart = void Function(ffi.Pointer<ffi.Void>, double);

typedef PlayerSetLimiterRatioC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef PlayerSetLimiterRatioDart = void Function(ffi.Pointer<ffi.Void>, double);

class RustAudioPlayer {
  late final ffi.DynamicLibrary _lib;
  ffi.Pointer<ffi.Void>? _playerPtr;

  late final PlayerCreateDart _playerCreate;
  late final PlayerDestroyDart _playerDestroy;
  late final PlayerLoadDart _playerLoad;
  late final PlayerPlayDart _playerPlay;
  late final PlayerPauseDart _playerPause;
  late final PlayerStopDart _playerStop;
  late final PlayerSeekDart _playerSeek;
  late final PlayerGetPositionDart _playerGetPosition;
  late final PlayerGetDurationDart _playerGetDuration;
  late final PlayerIsPlayingDart _playerIsPlaying;

  late final PlayerGetDeviceNameDart _playerGetDeviceName;
  late final PlayerGetDeviceSampleRateDart _playerGetDeviceSampleRate;
  late final PlayerGetDeviceChannelsDart _playerGetDeviceChannels;

  late final PlayerSetPreampDart _playerSetPreamp;
  late final PlayerSetEqBandDart _playerSetEqBand;
  late final PlayerSetStereoExpansionDart _playerSetStereoExpansion;
  late final PlayerSetStereoPanDart _playerSetStereoPan;
  late final PlayerSetReverbRoomSizeDart _playerSetReverbRoomSize;
  late final PlayerSetReverbMixDart _playerSetReverbMix;
  late final PlayerSetLimiterEnabledDart _playerSetLimiterEnabled;
  late final PlayerSetLimiterThresholdDart _playerSetLimiterThreshold;
  late final PlayerSetLimiterRatioDart _playerSetLimiterRatio;

  RustAudioPlayer() {
    _loadLibrary();
    _initFunctions();
    _playerPtr = _playerCreate();
    if (_playerPtr == null || _playerPtr!.address == 0) {
      throw Exception("Failed to initialize Rust Player");
    }
  }

  void _loadLibrary() {
    if (Platform.isAndroid) {
      _lib = ffi.DynamicLibrary.open('librust_audio_engine.so');
      return;
    }
    final List<String> pathsToTry = [];
    const absolutePath = r'C:\Users\2025\Documents\GitHub\music application\rust_audio_engine\target\release\rust_audio_engine.dll';
    pathsToTry.add(absolutePath);
    const absoluteDebugPath = r'C:\Users\2025\Documents\GitHub\music application\rust_audio_engine\target\debug\rust_audio_engine.dll';
    pathsToTry.add(absoluteDebugPath);
    final exeDir = p.dirname(Platform.resolvedExecutable);
    pathsToTry.add(p.join(exeDir, 'rust_audio_engine.dll'));
    try {
      Directory dir = Directory(exeDir);
      for (int i = 0; i < 6; i++) {
        if (dir.parent.path != dir.path) {
          dir = dir.parent;
        }
      }
      pathsToTry.add(p.join(dir.path, 'rust_audio_engine', 'target', 'release', 'rust_audio_engine.dll'));
      pathsToTry.add(p.join(dir.path, 'rust_audio_engine', 'target', 'debug', 'rust_audio_engine.dll'));
    } catch (_) {}
    pathsToTry.add('rust_audio_engine.dll');
    for (final path in pathsToTry) {
      try {
        if (path == 'rust_audio_engine.dll') {
          _lib = ffi.DynamicLibrary.open(path);
          return;
        }
        final file = File(path);
        if (file.existsSync()) {
          _lib = ffi.DynamicLibrary.open(path);
          return;
        }
      } catch (_) {}
    }
    try {
      _lib = ffi.DynamicLibrary.open('rust_audio_engine.dll');
    } catch (e) {
      throw Exception('Could not load rust_audio_engine.dll. Checked paths: $pathsToTry. Error: $e');
    }
  }

  void _initFunctions() {
    _playerCreate = _lib
        .lookup<ffi.NativeFunction<PlayerCreateC>>('player_create')
        .asFunction<PlayerCreateDart>();
    _playerDestroy = _lib
        .lookup<ffi.NativeFunction<PlayerDestroyC>>('player_destroy')
        .asFunction<PlayerDestroyDart>();
    _playerLoad = _lib
        .lookup<ffi.NativeFunction<PlayerLoadC>>('player_load')
        .asFunction<PlayerLoadDart>();
    _playerPlay = _lib
        .lookup<ffi.NativeFunction<PlayerPlayC>>('player_play')
        .asFunction<PlayerPlayDart>();
    _playerPause = _lib
        .lookup<ffi.NativeFunction<PlayerPauseC>>('player_pause')
        .asFunction<PlayerPauseDart>();
    _playerStop = _lib
        .lookup<ffi.NativeFunction<PlayerStopC>>('player_stop')
        .asFunction<PlayerStopDart>();
    _playerSeek = _lib
        .lookup<ffi.NativeFunction<PlayerSeekC>>('player_seek')
        .asFunction<PlayerSeekDart>();
    _playerGetPosition = _lib
        .lookup<ffi.NativeFunction<PlayerGetPositionC>>('player_get_position')
        .asFunction<PlayerGetPositionDart>();
    _playerGetDuration = _lib
        .lookup<ffi.NativeFunction<PlayerGetDurationC>>('player_get_duration')
        .asFunction<PlayerGetDurationDart>();
    _playerIsPlaying = _lib
        .lookup<ffi.NativeFunction<PlayerIsPlayingC>>('player_is_playing')
        .asFunction<PlayerIsPlayingDart>();
    _playerGetDeviceName = _lib
        .lookup<ffi.NativeFunction<PlayerGetDeviceNameC>>('player_get_device_name')
        .asFunction<PlayerGetDeviceNameDart>();
    _playerGetDeviceSampleRate = _lib
        .lookup<ffi.NativeFunction<PlayerGetDeviceSampleRateC>>('player_get_device_sample_rate')
        .asFunction<PlayerGetDeviceSampleRateDart>();
    _playerGetDeviceChannels = _lib
        .lookup<ffi.NativeFunction<PlayerGetDeviceChannelsC>>('player_get_device_channels')
        .asFunction<PlayerGetDeviceChannelsDart>();

    _playerSetPreamp = _lib
        .lookup<ffi.NativeFunction<PlayerSetPreampC>>('player_set_preamp')
        .asFunction<PlayerSetPreampDart>();
    _playerSetEqBand = _lib
        .lookup<ffi.NativeFunction<PlayerSetEqBandC>>('player_set_eq_band')
        .asFunction<PlayerSetEqBandDart>();
    _playerSetStereoExpansion = _lib
        .lookup<ffi.NativeFunction<PlayerSetStereoExpansionC>>('player_set_stereo_expansion')
        .asFunction<PlayerSetStereoExpansionDart>();
    _playerSetStereoPan = _lib
        .lookup<ffi.NativeFunction<PlayerSetStereoPanC>>('player_set_stereo_pan')
        .asFunction<PlayerSetStereoPanDart>();
    _playerSetReverbRoomSize = _lib
        .lookup<ffi.NativeFunction<PlayerSetReverbRoomSizeC>>('player_set_reverb_room_size')
        .asFunction<PlayerSetReverbRoomSizeDart>();
    _playerSetReverbMix = _lib
        .lookup<ffi.NativeFunction<PlayerSetReverbMixC>>('player_set_reverb_mix')
        .asFunction<PlayerSetReverbMixDart>();
    _playerSetLimiterEnabled = _lib
        .lookup<ffi.NativeFunction<PlayerSetLimiterEnabledC>>('player_set_limiter_enabled')
        .asFunction<PlayerSetLimiterEnabledDart>();
    _playerSetLimiterThreshold = _lib
        .lookup<ffi.NativeFunction<PlayerSetLimiterThresholdC>>('player_set_limiter_threshold')
        .asFunction<PlayerSetLimiterThresholdDart>();
    _playerSetLimiterRatio = _lib
        .lookup<ffi.NativeFunction<PlayerSetLimiterRatioC>>('player_set_limiter_ratio')
        .asFunction<PlayerSetLimiterRatioDart>();
  }

  void dispose() {
    final ptr = _playerPtr;
    if (ptr != null && ptr.address != 0) {
      _playerDestroy(ptr);
      _playerPtr = null;
    }
  }

  int load(String filePath) {
    final ptr = _playerPtr;
    if (ptr == null) return -3;
    final pathPtr = filePath.toNativeUtf8();
    try {
      return _playerLoad(ptr, pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  void play() {
    final ptr = _playerPtr;
    if (ptr != null) _playerPlay(ptr);
  }

  void pause() {
    final ptr = _playerPtr;
    if (ptr != null) _playerPause(ptr);
  }

  void stop() {
    final ptr = _playerPtr;
    if (ptr != null) _playerStop(ptr);
  }

  void seek(double seconds) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSeek(ptr, seconds);
  }

  int getPositionMs() {
    final ptr = _playerPtr;
    return ptr != null ? _playerGetPosition(ptr) : 0;
  }

  int getDurationMs() {
    final ptr = _playerPtr;
    return ptr != null ? _playerGetDuration(ptr) : 0;
  }

  bool isPlaying() {
    final ptr = _playerPtr;
    return ptr != null ? _playerIsPlaying(ptr) : false;
  }

  String getDeviceName() {
    final buffer = calloc<ffi.Uint8>(256);
    try {
      final res = _playerGetDeviceName(buffer, 256);
      if (res > 0) {
        return buffer.cast<Utf8>().toDartString();
      }
      return 'Default Speaker';
    } catch (_) {
      return 'Default Speaker';
    } finally {
      calloc.free(buffer);
    }
  }

  int getDeviceSampleRate() {
    try {
      return _playerGetDeviceSampleRate();
    } catch (_) {
      return 44100;
    }
  }

  int getDeviceChannels() {
    try {
      return _playerGetDeviceChannels();
    } catch (_) {
      return 2;
    }
  }

  void setPreamp(double db) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetPreamp(ptr, db);
  }

  void setEqBand(int bandIdx, double db) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetEqBand(ptr, bandIdx, db);
  }

  void setStereoExpansion(double percent) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetStereoExpansion(ptr, percent);
  }

  void setStereoPan(double pan) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetStereoPan(ptr, pan);
  }

  void setReverbRoomSize(double percent) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetReverbRoomSize(ptr, percent);
  }

  void setReverbMix(double percent) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetReverbMix(ptr, percent);
  }

  void setLimiterEnabled(bool enabled) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetLimiterEnabled(ptr, enabled);
  }

  void setLimiterThreshold(double db) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetLimiterThreshold(ptr, db);
  }

  void setLimiterRatio(double ratio) {
    final ptr = _playerPtr;
    if (ptr != null) _playerSetLimiterRatio(ptr, ratio);
  }
}
