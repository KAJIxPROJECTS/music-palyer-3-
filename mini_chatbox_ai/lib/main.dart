import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:onnxruntime/onnxruntime.dart';
import 'rust_audio_bindings.dart';
import 'win32_file_picker.dart';
import 'tinybert_classifier.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    OrtEnv.instance.init();
  } catch (e) {
    debugPrint("Failed to initialize ONNX Runtime: $e");
  }
  runApp(const VibeSyncApp());
}

class VibeSyncApp extends StatelessWidget {
  const VibeSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Player 4',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF36453F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF698075),
          secondary: Color(0xFFB5A296),
          surface: Colors.white,
          background: Color(0xFF36453F),
        ),
        textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'Segoe UI',
            ),
      ),
      home: const MainPlayerScreen(),
    );
  }
}

class MainPlayerScreen extends StatefulWidget {
  const MainPlayerScreen({super.key});

  @override
  State<MainPlayerScreen> createState() => _MainPlayerScreenState();
}

class _MainPlayerScreenState extends State<MainPlayerScreen> with TickerProviderStateMixin {
  RustAudioPlayer? _player;
  bool _isPlayerInitialized = false;
  final TinyBertClassifier _bertClassifier = TinyBertClassifier();

  String _detectedDeviceName = 'Detecting...';
  int _detectedSampleRate = 0;
  int _detectedChannels = 0;

  List<String> _playlist = [];
  int _currentTrackIndex = -1;
  bool _isPlaying = false;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isLiked = false;
  bool _isLooping = false;

  int _navigationIndex = 1;

  Timer? _stateTimer;
  Timer? _visualizerTimer;
  List<double> _waveHeights = List.generate(35, (_) => 2.0);

  final List<Map<String, dynamic>> _chatMessages = [
    {
      'isUser': false,
      'text': "Hi! I am your AI Music Assistant. Ask me to 'play', 'pause', 'stop', 'next', 'prev', 'loop', or 'status'!",
      'time': DateTime.now()
    }
  ];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  String _audioOutputDevice = 'Built-in Speaker';
  double _equalizerBass = 0.5;
  double _equalizerTreble = 0.5;

  late AnimationController _vinylController;

  @override
  void initState() {
    super.initState();
    _vinylController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );

    try {
      _player = RustAudioPlayer();
      _isPlayerInitialized = true;
      _stateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _updatePlaybackState();
      });
      _visualizerTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        _updateVisualizer();
      });
    } catch (_) {
    }
    _bertClassifier.init().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _visualizerTimer?.cancel();
    _player?.dispose();
    _vinylController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _bertClassifier.dispose();
    super.dispose();
  }

  void _updatePlaybackState() {
    if (_player == null) return;
    final playing = _player!.isPlaying();
    final pos = _player!.getPositionMs();
    final dur = _player!.getDurationMs();

    final currentDeviceName = _player!.getDeviceName();
    final currentSampleRate = _player!.getDeviceSampleRate();
    final currentChannels = _player!.getDeviceChannels();

    if (playing != _isPlaying ||
        pos != _positionMs ||
        dur != _durationMs ||
        currentDeviceName != _detectedDeviceName ||
        currentSampleRate != _detectedSampleRate ||
        currentChannels != _detectedChannels) {
      setState(() {
        _isPlaying = playing;
        _positionMs = pos;
        _durationMs = dur;
        _detectedDeviceName = currentDeviceName;
        _detectedSampleRate = currentSampleRate;
        _detectedChannels = currentChannels;

        if (_isPlaying) {
          if (!_vinylController.isAnimating) {
            _vinylController.repeat();
          }
        } else {
          if (_vinylController.isAnimating) {
            _vinylController.stop();
          }
        }
      });
    }

    if (_durationMs > 0 && _positionMs >= _durationMs) {
      if (_isLooping) {
        _player?.seek(0.0);
        _player?.play();
      } else {
        _nextTrack();
      }
    }
  }

  void _updateVisualizer() {
    if (!_isPlaying) {
      if (_waveHeights.any((h) => h > 2.0)) {
        setState(() {
          _waveHeights = List.generate(35, (_) => 2.0);
        });
      }
      return;
    }
    final rand = math.Random();
    setState(() {
      _waveHeights = List.generate(35, (_) => rand.nextDouble() * 20.0 + 2.0);
    });
  }

  void _loadAndPlay(int index) {
    if (_player == null || index < 0 || index >= _playlist.length) return;
    final path = _playlist[index];
    _player!.stop();
    final res = _player!.load(path);
    if (res == 0) {
      _player!.play();
      setState(() {
        _currentTrackIndex = index;
        _isPlaying = true;
        _positionMs = 0;
        _durationMs = 0;
      });
    }
  }

  void _togglePlayPause() {
    if (_player == null) return;
    if (_currentTrackIndex == -1 && _playlist.isNotEmpty) {
      _loadAndPlay(0);
      return;
    }
    if (_isPlaying) {
      _player!.pause();
    } else {
      _player!.play();
    }
  }

  void _nextTrack() {
    if (_playlist.isEmpty) return;
    final next = (_currentTrackIndex + 1) % _playlist.length;
    _loadAndPlay(next);
  }

  void _prevTrack() {
    if (_playlist.isEmpty) return;
    int prev = _currentTrackIndex - 1;
    if (prev < 0) {
      prev = _playlist.length - 1;
    }
    _loadAndPlay(prev);
  }

  void _seek(double ratio) {
    if (_player == null || _currentTrackIndex == -1 || _durationMs <= 0) return;
    final targetMs = ratio * _durationMs;
    _player!.seek(targetMs / 1000.0);
    setState(() {
      _positionMs = targetMs.toInt();
    });
  }

  Future<List<String>> _scanForAudioFiles() async {
    final List<String> paths = [];
    final List<String> dirs = [];
    if (Platform.isWindows) {
      final user = Platform.environment['USERPROFILE'];
      if (user != null) {
        dirs.add(p.join(user, 'Music'));
        dirs.add(p.join(user, 'Downloads'));
      }
      dirs.add(Directory.current.path);
    } else if (Platform.isAndroid) {
      dirs.add('/storage/emulated/0/Music');
      dirs.add('/storage/emulated/0/Download');
      dirs.add('/sdcard/Music');
      dirs.add('/sdcard/Download');
    }
    for (final d in dirs) {
      try {
        final directory = Directory(d);
        if (await directory.exists()) {
          final entities = await directory.list().toList();
          for (final e in entities) {
            if (e is File) {
              final ext = p.extension(e.path).toLowerCase();
              if (ext == '.mp3' || ext == '.wav' || ext == '.ogg' || ext == '.flac' || ext == '.m4a') {
                paths.add(e.path);
              }
            }
          }
        }
      } catch (_) {}
    }
    return paths;
  }

  void _showFileScannerSheet() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2824),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      builder: (context) {
        return FutureBuilder<List<String>>(
          future: _scanForAudioFiles(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: Color(0xFFB5A296)));
            }
            final files = snapshot.data ?? [];
            if (files.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_off_rounded, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text('No audio files found in default directories.', style: TextStyle(color: Colors.white)),
                    const SizedBox(height: 16),
                    if (Platform.isWindows)
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          final path = Win32FilePicker.pickFile();
                          if (path != null) {
                            setState(() {
                              _playlist.add(path);
                              if (_currentTrackIndex == -1) _currentTrackIndex = 0;
                            });
                          }
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF698075)),
                        child: const Text('Browse manually'),
                      ),
                  ],
                ),
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text('Discovered Audio Files', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final path = files[index];
                      final name = p.basename(path);
                      return ListTile(
                        leading: const Icon(Icons.audiotrack, color: Color(0xFFB5A296)),
                        title: Text(name, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(p.dirname(path), style: const TextStyle(color: Colors.grey, fontSize: 10)),
                        onTap: () {
                          setState(() {
                            if (!_playlist.contains(path)) {
                              _playlist.add(path);
                            }
                            if (_currentTrackIndex == -1) {
                              _currentTrackIndex = _playlist.indexOf(path);
                            }
                          });
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showPlaylistSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2824),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text('Current Queue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
                if (_playlist.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Text('Queue is empty. Tap the share button to import.', style: TextStyle(color: Colors.grey)),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      itemCount: _playlist.length,
                      itemBuilder: (context, index) {
                        final path = _playlist[index];
                        final name = p.basename(path);
                        final isActive = index == _currentTrackIndex;
                        return ListTile(
                          leading: Icon(isActive ? Icons.play_circle_fill : Icons.audiotrack, color: isActive ? const Color(0xFF00FFFF) : const Color(0xFFB5A296)),
                          title: Text(name, style: TextStyle(color: isActive ? Colors.white : const Color(0xFFE2E4F0), fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            onPressed: () {
                              setState(() {
                                if (_currentTrackIndex == index) {
                                  _player?.stop();
                                  _currentTrackIndex = -1;
                                  _isPlaying = false;
                                } else if (_currentTrackIndex > index) {
                                  _currentTrackIndex--;
                                }
                                _playlist.removeAt(index);
                              });
                              setModalState(() {});
                            },
                          ),
                          onTap: () {
                            _loadAndPlay(index);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleSendChatMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _chatController.clear();
    setState(() {
      _chatMessages.add({
        'isUser': true,
        'text': text,
        'time': DateTime.now(),
      });
    });
    _scrollChatToBottom();
    _processChatAICommand(text);
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addAIChatMessage(String text) {
    setState(() {
      _chatMessages.add({
        'isUser': false,
        'text': text,
        'time': DateTime.now(),
      });
    });
    _scrollChatToBottom();
  }

  void _processChatAICommand(String input) {
    final cmd = input.toLowerCase();
    _bertClassifier.runInference(input).then((bertOutput) {
      if (bertOutput != null && bertOutput.isNotEmpty) {
        final length = bertOutput.length > 5 ? 5 : bertOutput.length;
        final slice = bertOutput.sublist(0, length).map((e) => e.toStringAsFixed(3)).join(', ');
        debugPrint("[TinyBERT Inference Output: $slice...]");
      }
      Timer(const Duration(milliseconds: 400), () {
        if (cmd.contains('play')) {
          if (_playlist.isEmpty) {
            _addAIChatMessage("Queue is empty. Use the share button on player to scan and add tracks, or type 'scan'.");
          } else {
            _togglePlayPause();
            if (!_isPlaying) {
              _addAIChatMessage("Resumed audio playback.");
            } else {
              _addAIChatMessage("Playing track: ${p.basename(_playlist[_currentTrackIndex])}");
            }
          }
        } else if (cmd.contains('pause') || cmd.contains('hold')) {
          if (_isPlaying) {
            _player?.pause();
            _addAIChatMessage("Audio playback paused.");
          } else {
            _addAIChatMessage("Playback is already paused.");
          }
        } else if (cmd.contains('stop')) {
          _player?.stop();
          _addAIChatMessage("Playback stopped and timeline reset.");
        } else if (cmd.contains('next') || cmd.contains('skip')) {
          if (_playlist.isNotEmpty) {
            _nextTrack();
            _addAIChatMessage("Skipped to next track.");
          } else {
            _addAIChatMessage("No tracks in queue.");
          }
        } else if (cmd.contains('prev') || cmd.contains('back')) {
          if (_playlist.isNotEmpty) {
            _prevTrack();
            _addAIChatMessage("Playing previous track.");
          } else {
            _addAIChatMessage("No tracks in queue.");
          }
        } else if (cmd.contains('loop') || cmd.contains('repeat')) {
          setState(() {
            _isLooping = !_isLooping;
          });
          _addAIChatMessage(_isLooping ? "Loop mode enabled." : "Loop mode disabled.");
        } else if (cmd.contains('scan') || cmd.contains('import')) {
          _addAIChatMessage("Scanning local storage for audio files...");
          _scanForAudioFiles().then((files) {
            if (files.isNotEmpty) {
              setState(() {
                for (final f in files) {
                  if (!_playlist.contains(f)) _playlist.add(f);
                }
                if (_currentTrackIndex == -1) _currentTrackIndex = 0;
              });
              _addAIChatMessage("Discovered and imported ${files.length} tracks to queue.");
            } else {
              _addAIChatMessage("No audio files discovered.");
            }
          });
        } else if (cmd.contains('status') || cmd.contains('info')) {
          if (_currentTrackIndex != -1) {
            final title = p.basename(_playlist[_currentTrackIndex]);
            final pos = _formatDuration(_positionMs);
            final dur = _formatDuration(_durationMs);
            final state = _isPlaying ? "Playing" : "Paused";
            _addAIChatMessage("Status: $state\nTrack: $title\nProgress: $pos / $dur");
          } else {
            _addAIChatMessage("No track is currently loaded.");
          }
        } else if (cmd.contains('hello') || cmd.contains('hi') || cmd.contains('hey') || cmd.contains('sup') || cmd.contains('yo')) {
          _addAIChatMessage("Hello! I am your AI Music Assistant. How can I help you today? You can ask me to play, pause, scan, or get the status of your music.");
        } else if (cmd.contains('how are you') || cmd.contains('how\'s it going') || cmd.contains('how is it going')) {
          _addAIChatMessage("I'm doing great, thank you! Ready to play some awesome music. How can I assist you?");
        } else if (cmd.contains('who are you') || cmd.contains('what is your name')) {
          _addAIChatMessage("I am VibeSync AI, your offline music companion.");
        } else if (cmd.contains('thank') || cmd.contains('thanks')) {
          _addAIChatMessage("You're very welcome! Let me know if you need anything else, or if you'd like to hear another track.");
        } else if (cmd.contains('bye') || cmd.contains('goodbye')) {
          _addAIChatMessage("Goodbye! Have a great day with good music.");
        } else {
          _addAIChatMessage("I'm here to chat, but I'm best at controlling your music! You can tell me to 'play', 'pause', 'stop', 'next', 'prev', 'loop', or 'scan'.");
        }
      });
    });
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return "0:00";
    final sec = (ms / 1000).round();
    final m = sec ~/ 60;
    final s = sec % 60;
    return "$m:${s.toString().padLeft(2, '0')}";
  }

  ImageProvider _getAlbumArt() {
    if (_currentTrackIndex == -1 || _playlist.isEmpty) {
      return const AssetImage('assets/cactus_pot.png');
    }
    final trackPath = _playlist[_currentTrackIndex];
    final dir = p.dirname(trackPath);
    final baseName = p.basenameWithoutExtension(trackPath);
    final extensions = ['.jpg', '.jpeg', '.png'];
    for (final ext in extensions) {
      final imgPath = p.join(dir, '$baseName$ext');
      if (File(imgPath).existsSync()) {
        return FileImage(File(imgPath));
      }
    }
    for (final ext in extensions) {
      final coverPath = p.join(dir, 'cover$ext');
      if (File(coverPath).existsSync()) {
        return FileImage(File(coverPath));
      }
      final folderPath = p.join(dir, 'folder$ext');
      if (File(folderPath).existsSync()) {
        return FileImage(File(folderPath));
      }
    }
    return const AssetImage('assets/cactus_pot.png');
  }

  Widget _buildSettingsView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          const Text(
            'Settings',
            style: TextStyle(color: Color(0xFF1E2824), fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              children: [
                _buildSettingsHeader('Audio Setup'),
                _buildSettingsDropdownTile(
                  title: 'Output Device',
                  value: _audioOutputDevice,
                  items: ['Built-in Speaker', 'Headphones', 'Bluetooth Device'],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _audioOutputDevice = val;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsHeader('Output Capabilities'),
                _buildCapabilitiesPanel(),
                const SizedBox(height: 12),
                _buildSettingsHeader('Playback Settings'),
                _buildSettingsSwitchTile(
                  title: 'Repeat Single Track',
                  value: _isLooping,
                  onChanged: (val) {
                    setState(() {
                      _isLooping = val;
                    });
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsHeader('Equalizer Controls'),
                _buildSettingsSliderTile(
                  title: 'Bass Boost',
                  value: _equalizerBass,
                  onChanged: (val) {
                    setState(() {
                      _equalizerBass = val;
                    });
                  },
                ),
                _buildSettingsSliderTile(
                  title: 'Treble Boost',
                  value: _equalizerTreble,
                  onChanged: (val) {
                    setState(() {
                      _equalizerTreble = val;
                    });
                  },
                ),
                const SizedBox(height: 20),
                const Center(
                  child: Text(
                    'Music Player 4 v1.0.0',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilitiesPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCapabilityRow('Device Name', _detectedDeviceName),
          const SizedBox(height: 8),
          _buildCapabilityRow('Sample Rate', _detectedSampleRate > 0 ? '$_detectedSampleRate Hz' : 'Unknown'),
          const SizedBox(height: 8),
          _buildCapabilityRow('Channels', _detectedChannels > 0 ? '$_detectedChannels channels' : 'Unknown'),
        ],
      ),
    );
  }

  Widget _buildCapabilityRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF698075), fontSize: 13, fontWeight: FontWeight.w600)),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(color: Color(0xFF1E2824), fontSize: 13, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
      child: Text(
        title,
        style: const TextStyle(color: Color(0xFF698075), fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5),
      ),
    );
  }

  Widget _buildSettingsDropdownTile({
    required String title,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(color: Color(0xFF1E2824), fontSize: 14, fontWeight: FontWeight.w600)),
          DropdownButton<String>(
            value: value,
            underline: const SizedBox(),
            dropdownColor: Colors.white,
            style: const TextStyle(color: Color(0xFF1E2824), fontSize: 13, fontWeight: FontWeight.bold),
            items: items.map((String val) {
              return DropdownMenuItem<String>(
                value: val,
                child: Text(val),
              );
            }).toList(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSwitchTile({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(color: Color(0xFF1E2824), fontSize: 14, fontWeight: FontWeight.w600)),
          Switch(
            value: value,
            activeColor: const Color(0xFF698075),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSliderTile({
    required String title,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(title, style: const TextStyle(color: Color(0xFF1E2824), fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 3,
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: const Color(0xFF698075),
                inactiveTrackColor: Colors.grey[300],
                thumbColor: const Color(0xFF698075),
                trackHeight: 3,
              ),
              child: Slider(
                value: value,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'AI Assistant',
                style: TextStyle(color: Color(0xFF1E2824), fontSize: 22, fontWeight: FontWeight.bold),
              ),
              Text(
                _bertClassifier.isReady
                    ? 'TinyBERT Online'
                    : (_bertClassifier.isDownloading ? 'TinyBERT Downloading...' : 'TinyBERT Offline'),
                style: TextStyle(
                  color: _bertClassifier.isReady ? Colors.green : Colors.orange,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              controller: _chatScrollController,
              itemCount: _chatMessages.length,
              itemBuilder: (context, index) {
                final m = _chatMessages[index];
                final isUser = m['isUser'] as bool;
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF698075) : const Color(0xFFECEFF0),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(14),
                        topRight: const Radius.circular(14),
                        bottomLeft: isUser ? const Radius.circular(14) : Radius.zero,
                        bottomRight: isUser ? Radius.zero : const Radius.circular(14),
                      ),
                    ),
                    child: Text(
                      m['text'] as String,
                      style: TextStyle(color: isUser ? Colors.white : const Color(0xFF1E2824), fontSize: 13),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    onSubmitted: (_) => _handleSendChatMessage(),
                    style: const TextStyle(color: Color(0xFF1E2824), fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Type a music command...',
                      hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFFECEFF0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: const Color(0xFF698075),
                  radius: 18,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.send, color: Colors.white, size: 16),
                    onPressed: _handleSendChatMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerView(double heightFactor) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 130 * heightFactor,
          child: GestureDetector(
            onTap: _showPlaylistSheet,
            child: Container(
              width: 32,
              height: 100,
              decoration: const BoxDecoration(
                color: Color(0xFF698075),
                borderRadius: BorderRadius.only(topRight: Radius.circular(16), bottomRight: Radius.circular(16)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(width: 2, height: 12, color: Colors.white),
                  const SizedBox(height: 4),
                  const RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      'PLAYLIST',
                      style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 4,
                    height: 4,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 180 * heightFactor,
          child: GestureDetector(
            onTap: _showFileScannerSheet,
            child: Container(
              width: 32,
              height: 40,
              decoration: const BoxDecoration(
                color: Color(0xFF698075),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(12), bottomLeft: Radius.circular(12)),
              ),
              child: const Center(
                child: Icon(Icons.library_music, color: Colors.white, size: 14),
              ),
            ),
          ),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Now playing',
              style: TextStyle(color: Color(0xFF1E2824), fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Center(
              child: SizedBox(
                width: 180,
                height: 180,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CircularProgressIndicator(
                        value: _durationMs > 0 ? _positionMs / _durationMs : 0.23,
                        strokeWidth: 3,
                        backgroundColor: const Color(0xFFE0E5E2),
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF698075)),
                      ),
                    ),
                    Positioned.fill(
                      child: Transform.rotate(
                        angle: (_durationMs > 0 ? _positionMs / _durationMs : 0.23) * 2 * math.pi,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Color(0xFF36453F),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: Container(
                        width: 155,
                        height: 155,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          shape: BoxShape.circle,
                        ),
                        child: ClipOval(
                          child: Image(
                            image: _getAlbumArt(),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                children: [
                  Text(
                    _currentTrackIndex != -1 ? p.basenameWithoutExtension(_playlist[_currentTrackIndex]).toUpperCase() : 'TAK INGIN USAI',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF1E2824), fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _currentTrackIndex != -1 ? 'Local Audio' : 'Keisya Levronka',
                        style: const TextStyle(color: Color(0xFF698075), fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.check_circle, color: Color(0xFF698075), size: 12),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                const Text(
                  'Duration',
                  style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(_positionMs),
                        style: const TextStyle(color: Color(0xFF1E2824), fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _formatDuration(_durationMs > 0 ? _durationMs : 279000),
                        style: const TextStyle(color: Color(0xFF1E2824), fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF698075),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 4),
                      RotationTransition(
                        turns: _vinylController,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [Color(0xFF333333), Color(0xFF000000)],
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF698075),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Container(
                          height: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 6.0),
                          child: GestureDetector(
                            onHorizontalDragUpdate: (details) {
                              final box = context.findRenderObject() as RenderBox;
                              final localOffset = box.globalToLocal(details.globalPosition);
                              final width = box.size.width - 100;
                              final ratio = (localOffset.dx - 50).clamp(0.0, width) / width;
                              _seek(ratio);
                            },
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: List.generate(35, (index) {
                                final isActive = _durationMs > 0 && (_positionMs / _durationMs * 35) > index;
                                return Container(
                                  width: 2,
                                  height: _waveHeights[index],
                                  decoration: BoxDecoration(
                                    color: isActive ? Colors.white : Colors.white.withOpacity(0.4),
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous, color: Colors.white, size: 16),
                        onPressed: _prevTrack,
                      ),
                      IconButton(
                        icon: const Icon(Icons.fast_rewind, color: Colors.white, size: 18),
                        onPressed: () {
                          if (_durationMs > 0) {
                            final target = (_positionMs - 5000).clamp(0, _durationMs);
                            _player?.seek(target / 1000.0);
                          }
                        },
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: const Color(0xFF698075),
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.fast_forward, color: Colors.white, size: 18),
                        onPressed: () {
                          if (_durationMs > 0) {
                            final target = (_positionMs + 5000).clamp(0, _durationMs);
                            _player?.seek(target / 1000.0);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next, color: Colors.white, size: 16),
                        onPressed: _nextTrack,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    final double width = isMobile ? size.width : 390.0;
    final double height = isMobile ? size.height : 780.0;
    final double heightFactor = height / 780.0;

    Widget cardContent;
    if (_navigationIndex == 0) {
      cardContent = _buildSettingsView();
    } else if (_navigationIndex == 2) {
      cardContent = _buildChatView();
    } else {
      cardContent = _buildPlayerView(heightFactor);
    }

    Widget playerBody = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF36453F),
        borderRadius: isMobile ? BorderRadius.zero : BorderRadius.circular(40),
        boxShadow: isMobile
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 30,
                  spreadRadius: 5,
                )
              ],
      ),
      child: ClipRRect(
        borderRadius: isMobile ? BorderRadius.zero : BorderRadius.circular(40),
        child: Stack(
          children: [
            Positioned(
              top: -60,
              left: -40,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFB5A296).withOpacity(0.6),
                ),
              ),
            ),
            Positioned(
              top: -80,
              right: -80,
              child: Container(
                width: 320,
                height: 180,
                decoration: BoxDecoration(
                  color: const Color(0xFF222B27).withOpacity(0.5),
                  borderRadius: BorderRadius.circular(90),
                ),
              ),
            ),
            Column(
              children: [
                const SizedBox(height: 48),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, left: 12, right: 12, bottom: 12),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.all(Radius.circular(40)),
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(40)),
                      child: cardContent,
                    ),
                  ),
                ),
                Container(
                  height: 60,
                  color: const Color(0xFFB5A296),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.settings,
                          color: _navigationIndex == 0 ? const Color(0xFF36453F) : Colors.white70,
                        ),
                        onPressed: () {
                          setState(() {
                            _navigationIndex = 0;
                          });
                        },
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _navigationIndex = 1;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                          decoration: BoxDecoration(
                            color: _navigationIndex == 1 ? const Color(0xFF36453F) : const Color(0xFF36453F).withOpacity(0.5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.home, color: Color(0xFFB5A296), size: 20),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.chat_bubble,
                          color: _navigationIndex == 2 ? const Color(0xFF36453F) : Colors.white70,
                        ),
                        onPressed: () {
                          setState(() {
                            _navigationIndex = 2;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (isMobile) {
      return Scaffold(body: playerBody);
    }

    return Scaffold(
      body: Center(
        child: playerBody,
      ),
    );
  }
}
