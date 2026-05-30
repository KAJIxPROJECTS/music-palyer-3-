import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
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
      title: 'Music Player 3',
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
  String? _lastAIQuestion;
  String? _cachedArtPath;
  Uint8List? _cachedArtBytes;
  final Map<String, List<String>> _customPlaylists = {};
  String? _activePlaylistName;
  String _eqPreset = 'Flat';
  bool _customEqEnabled = false;
  final List<double> _eqBands = [0.0, 0.0, 0.0, 0.0, 0.0];
  double _preAmpGain = 0.0;
  double _stereoExpansion = 100.0;
  bool _surroundSound = false;
  String _reverbPreset = 'None';
  bool _eqIs10Band = false;
  final List<double> _eq10Bands = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
  double _eqBassBoost = 0.0;
  double _eqTrebleBoost = 0.0;
  double _eqVocalPresence = 0.0;
  double _stereoPan = 0.0;
  double _reverbRoomSize = 0.0;
  double _reverbMix = 0.0;
  bool _limiterEnabled = false;
  double _limiterThreshold = 0.0;
  double _limiterRatio = 1.0;
  final Map<String, Map<String, dynamic>> _savedPresets = {};
  DateTime? _lastSeekTime;

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

  String _audioOutputDevice = 'System Default Device';
  double _equalizerBass = 0.5;
  double _equalizerTreble = 0.5;

  late AnimationController _vinylController;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
    _loadSavedPresets();
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
    final dur = _player!.getDurationMs();
    int pos = _positionMs;
    if (_lastSeekTime == null || DateTime.now().difference(_lastSeekTime!) > const Duration(milliseconds: 500)) {
      pos = _player!.getPositionMs();
    }

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
        _lastSeekTime = DateTime.now();
        _positionMs = 0;
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
      _applyAllDSPToPlayer();
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
    if (_currentTrackIndex != -1 && _durationMs == 0) {
      _loadAndPlay(_currentTrackIndex);
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
    _lastSeekTime = DateTime.now();
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
                            if (!_playlist.contains(path)) {
                              setState(() {
                                _playlist.add(path);
                              });
                            }
                            final index = _playlist.indexOf(path);
                            _loadAndPlay(index);
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
                          if (!_playlist.contains(path)) {
                            setState(() {
                              _playlist.add(path);
                            });
                          }
                          final index = _playlist.indexOf(path);
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

  void _savePlaylists() {
    try {
      final file = File('playlists.json');
      final data = _customPlaylists.map((k, v) => MapEntry(k, v));
      file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  void _saveCustomPresets() {
    try {
      final file = File('custom_eq_presets.json');
      file.writeAsStringSync(jsonEncode(_savedPresets));
    } catch (_) {}
  }

  void _loadSavedPresets() {
    try {
      final file = File('custom_eq_presets.json');
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _savedPresets.clear();
        data.forEach((k, v) {
          _savedPresets[k] = Map<String, dynamic>.from(v as Map);
        });
      }
    } catch (_) {}
  }

  void _loadPlaylists() {
    try {
      final file = File('playlists.json');
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _customPlaylists.clear();
        data.forEach((k, v) {
          _customPlaylists[k] = List<String>.from(v as List);
        });
      }
    } catch (_) {}
  }

  void _showCreatePlaylistDialog(StateSetter setModalState) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2824),
          title: const Text('New Playlist', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Enter playlist name...',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFB5A296))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  setState(() {
                    if (!_customPlaylists.containsKey(name)) {
                      _customPlaylists[name] = [];
                      _savePlaylists();
                    }
                  });
                  setModalState(() {});
                }
                Navigator.pop(context);
              },
              child: const Text('Create', style: TextStyle(color: Color(0xFFB5A296))),
            ),
          ],
        );
      },
    );
  }

  void _showAddToPlaylistDialog(String trackPath) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2824),
          title: const Text('Add to Playlist', style: TextStyle(color: Colors.white)),
          content: _customPlaylists.isEmpty
              ? const Text('No playlists created yet. Create a playlist first.', style: TextStyle(color: Colors.grey))
              : Container(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _customPlaylists.length,
                    itemBuilder: (context, index) {
                      final name = _customPlaylists.keys.elementAt(index);
                      return ListTile(
                        leading: const Icon(Icons.playlist_add, color: Color(0xFFB5A296)),
                        title: Text(name, style: const TextStyle(color: Colors.white)),
                        onTap: () {
                          setState(() {
                            if (!_customPlaylists[name]!.contains(trackPath)) {
                              _customPlaylists[name]!.add(trackPath);
                              _savePlaylists();
                            }
                          });
                          Navigator.pop(context);
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              content: Text('Added to $name'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPlaylistsTab(StateSetter setModalState) {
    if (_activePlaylistName != null) {
      final tracks = _customPlaylists[_activePlaylistName] ?? [];
      return Column(
        children: [
          ListTile(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                setModalState(() {
                  _activePlaylistName = null;
                });
              },
            ),
            title: Text(_activePlaylistName!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_arrow, color: Colors.white70),
                  onPressed: () {
                    if (tracks.isNotEmpty) {
                      setState(() {
                        _playlist = List<String>.from(tracks);
                        _currentTrackIndex = 0;
                      });
                      _loadAndPlay(0);
                      Navigator.pop(context);
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.shuffle, color: Colors.white70),
                  onPressed: () {
                    if (tracks.isNotEmpty) {
                      final shuffled = List<String>.from(tracks)..shuffle(math.Random());
                      setState(() {
                        _playlist = shuffled;
                        _currentTrackIndex = 0;
                      });
                      _loadAndPlay(0);
                      Navigator.pop(context);
                    }
                  },
                ),
              ],
            ),
          ),
          if (tracks.isEmpty)
            const Expanded(
              child: Center(
                child: Text('This playlist is empty.', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final path = tracks[index];
                  final name = p.basename(path);
                  return ListTile(
                    leading: const Icon(Icons.audiotrack, color: Color(0xFFB5A296)),
                    title: Text(name, style: const TextStyle(color: Colors.white)),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                      onPressed: () {
                        setState(() {
                          _customPlaylists[_activePlaylistName!]!.removeAt(index);
                          _savePlaylists();
                        });
                        setModalState(() {});
                      },
                    ),
                    onTap: () {
                      setState(() {
                        _playlist = List<String>.from(tracks);
                        _currentTrackIndex = index;
                      });
                      _loadAndPlay(index);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: ElevatedButton.icon(
            onPressed: () => _showCreatePlaylistDialog(setModalState),
            icon: const Icon(Icons.add, color: Colors.white),
            label: const Text('Create New Playlist', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF698075),
              minimumSize: const Size.fromHeight(40),
            ),
          ),
        ),
        if (_customPlaylists.isEmpty)
          const Expanded(
            child: Center(
              child: Text('No playlists created yet.', style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _customPlaylists.length,
              itemBuilder: (context, index) {
                final key = _customPlaylists.keys.elementAt(index);
                final count = _customPlaylists[key]!.length;
                return ListTile(
                  leading: const Icon(Icons.playlist_play, color: Color(0xFFB5A296)),
                  title: Text(key, style: const TextStyle(color: Colors.white)),
                  subtitle: Text('$count tracks', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_arrow, color: Colors.white70),
                        onPressed: () {
                          final tracks = _customPlaylists[key];
                          if (tracks != null && tracks.isNotEmpty) {
                            setState(() {
                              _playlist = List<String>.from(tracks);
                              _currentTrackIndex = 0;
                            });
                            _loadAndPlay(0);
                            Navigator.pop(context);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.shuffle, color: Colors.white70),
                        onPressed: () {
                          final tracks = _customPlaylists[key];
                          if (tracks != null && tracks.isNotEmpty) {
                            final shuffled = List<String>.from(tracks)..shuffle(math.Random());
                            setState(() {
                              _playlist = shuffled;
                              _currentTrackIndex = 0;
                            });
                            _loadAndPlay(0);
                            Navigator.pop(context);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () {
                          setState(() {
                            _customPlaylists.remove(key);
                            _savePlaylists();
                          });
                          setModalState(() {});
                        },
                      ),
                    ],
                  ),
                  onTap: () {
                    setModalState(() {
                      _activePlaylistName = key;
                    });
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildQueueTab(StateSetter setModalState) {
    if (_playlist.isEmpty) {
      return const Center(
        child: Text('Queue is empty. Import tracks to begin.', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      itemCount: _playlist.length,
      itemBuilder: (context, index) {
        final path = _playlist[index];
        final name = p.basename(path);
        final isActive = index == _currentTrackIndex;
        return ListTile(
          leading: Icon(isActive ? Icons.play_circle_fill : Icons.audiotrack, color: isActive ? const Color(0xFF00FFFF) : const Color(0xFFB5A296)),
          title: Text(name, style: TextStyle(color: isActive ? Colors.white : const Color(0xFFE2E4F0), fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.playlist_add, color: Colors.white70),
                onPressed: () => _showAddToPlaylistDialog(path),
              ),
              IconButton(
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
            ],
          ),
          onTap: () {
            _loadAndPlay(index);
            Navigator.pop(context);
          },
        );
      },
    );
  }

  void _showPlaylistSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2824),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const TabBar(
                      indicatorColor: Color(0xFFB5A296),
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.grey,
                      tabs: [
                        Tab(text: 'Playlists'),
                        Tab(text: 'Current Queue'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildPlaylistsTab(setModalState),
                          _buildQueueTab(setModalState),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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

  bool _hasWord(String text, String word) {
    return RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false).hasMatch(text);
  }

  bool _hasAnyWord(String text, List<String> words) {
    return words.any((w) => RegExp('\\b${RegExp.escape(w)}\\b', caseSensitive: false).hasMatch(text));
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
        final rand = math.Random();
        if (_hasAnyWord(cmd, ['play', 'resume', 'start'])) {
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
        } else if (_hasAnyWord(cmd, ['pause', 'hold'])) {
          if (_isPlaying) {
            _player?.pause();
            _addAIChatMessage("Audio playback paused.");
          } else {
            _addAIChatMessage("Playback is already paused.");
          }
        } else if (_hasWord(cmd, 'stop')) {
          _player?.stop();
          _addAIChatMessage("Playback stopped and timeline reset.");
        } else if (_hasAnyWord(cmd, ['next', 'skip'])) {
          if (_playlist.isNotEmpty) {
            _nextTrack();
            _addAIChatMessage("Skipped to next track.");
          } else {
            _addAIChatMessage("No tracks in queue.");
          }
        } else if (_hasAnyWord(cmd, ['prev', 'back'])) {
          if (_playlist.isNotEmpty) {
            _prevTrack();
            _addAIChatMessage("Playing previous track.");
          } else {
            _addAIChatMessage("No tracks in queue.");
          }
        } else if (_hasAnyWord(cmd, ['loop', 'repeat'])) {
          setState(() {
            _isLooping = !_isLooping;
          });
          _addAIChatMessage(_isLooping ? "Loop mode enabled." : "Loop mode disabled.");
        } else if (_hasAnyWord(cmd, ['scan', 'import'])) {
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
        } else if (_hasAnyWord(cmd, ['status', 'info'])) {
          if (_currentTrackIndex != -1) {
            final title = p.basename(_playlist[_currentTrackIndex]);
            final pos = _formatDuration(_positionMs);
            final dur = _formatDuration(_durationMs);
            final state = _isPlaying ? "Playing" : "Paused";
            _addAIChatMessage("Status: $state\nTrack: $title\nProgress: $pos / $dur");
          } else {
            _addAIChatMessage("No track is currently loaded.");
          }
        } else if (_lastAIQuestion == 'mood' && _hasAnyWord(cmd, ['good', 'great', 'awesome', 'happy', 'fine', 'wonderful', 'cool', 'ok', 'okay', 'well'])) {
          _lastAIQuestion = null;
          final responses = [
            "Awesome! Glad to hear that. Want to play some energetic tracks?",
            "Fantastic! Let's keep the energy up. Should I play some music?",
            "Wonderful! What would you like to listen to?"
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
        } else if (_lastAIQuestion == 'mood' && _hasAnyWord(cmd, ['bad', 'sad', 'tired', 'stressed', 'angry', 'blue', 'down', 'exhausted'])) {
          _lastAIQuestion = null;
          final responses = [
            "I'm sorry to hear that. Music always helps me unwind. Should I play something relaxing?",
            "Aw, that's not good. Maybe a soft tune would help you feel better?",
            "Sending positive vibes your way. Let me know if you want to listen to some chill tracks to relax."
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
        } else if (cmd.contains('how are you') || cmd.contains("how's it going") || cmd.contains("how is it going")) {
          _lastAIQuestion = 'mood';
          final responses = [
            "I'm doing great, thank you for asking! How are you doing today?",
            "Systems are running perfectly! Ready for some music. How are you feeling?",
            "I'm vibing! Thanks for checking in. How is your day going?"
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
        } else if (_hasAnyWord(cmd, ['hello', 'hi', 'hey', 'sup', 'yo', 'greetings'])) {
          _lastAIQuestion = 'mood';
          final responses = [
            "Hello! I am your AI Music Assistant. How are you doing today?",
            "Hey there! Ready to listen to some music? How are you feeling?",
            "Hi! How has your day been so far?",
            "Greetings! How are you today?"
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
        } else if (_hasAnyWord(cmd, ['joke', 'jokes', 'funny'])) {
          final jokes = [
            "Why did the computer go to the dentist? Because it had Bluetooth!",
            "Why did the singer climb a ladder? To reach the high notes!",
            "What makes music in your hair? A head-band!",
            "What is an elf's favorite type of music? Wrap music!"
          ];
          _addAIChatMessage(jokes[rand.nextInt(jokes.length)]);
        } else if (_hasAnyWord(cmd, ['favorite', 'favourite', 'like', 'love']) && _hasAnyWord(cmd, ['music', 'song', 'genre', 'artist', 'tune', 'sound'])) {
          final responses = [
            "I love all kinds of music, but I have a soft spot for synthwave and chill lo-fi. What about you?",
            "I'm a big fan of electronic beats and acoustic melodies. Music makes the world go round!",
            "I think instrumental tracks are amazing for focusing. What's your favorite genre?"
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
        } else if (_hasAnyWord(cmd, ['recommend', 'suggestion', 'suggest', 'recommendation'])) {
          if (_playlist.isEmpty) {
            _addAIChatMessage("Your queue is currently empty, but I highly recommend importing some chill lo-fi tracks.");
          } else {
            final track = p.basename(_playlist[rand.nextInt(_playlist.length)]);
            _addAIChatMessage("You should check out '$track' in your queue! Let me know if you want me to play it.");
          }
        } else if (_hasAnyWord(cmd, ['time', 'clock'])) {
          final now = DateTime.now();
          final minutes = now.minute.toString().padLeft(2, '0');
          _addAIChatMessage("It is currently ${now.hour}:$minutes. The perfect time to sit back and listen to music!");
        } else if (_hasAnyWord(cmd, ['weather', 'temperature', 'rain', 'sun'])) {
          _addAIChatMessage("I don't have internet access to check the weather, but it's always a perfect day for music in here.");
        } else if (_hasAnyWord(cmd, ['thank', 'thanks', 'thankyou'])) {
          final responses = [
            "You're very welcome!",
            "Anytime! Let me know if you need more help.",
            "My pleasure! Enjoy the music."
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
        } else if (_hasAnyWord(cmd, ['bye', 'goodbye', 'seeya'])) {
          _addAIChatMessage("Goodbye! Have a great day and keep vibing.");
        } else {
          final responses = [
            "I'm here to chat, but I'm best at controlling your music! You can tell me to 'play', 'pause', 'stop', 'next', 'prev', 'loop', or 'scan'.",
            "I didn't quite catch that. You can ask me to play a track, show status, tell a joke, or recommend a song!",
            "I'm your music assistant. Try asking me to play, pause, scan for files, or check the player status!"
          ];
          _addAIChatMessage(responses[rand.nextInt(responses.length)]);
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

  Uint8List? _extractEmbeddedAlbumArt(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final raf = file.openSync(mode: FileMode.read);
      final header = raf.readSync(10);
      if (header.length < 4) {
        raf.closeSync();
        return null;
      }
      if (header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
        final majorVersion = header[3];
        final tagSize = ((header[6] & 0x7F) << 21) |
                        ((header[7] & 0x7F) << 14) |
                        ((header[8] & 0x7F) << 7) |
                        (header[9] & 0x7F);
        final tagBytes = raf.readSync(tagSize);
        raf.closeSync();
        int offset = 0;
        while (offset + 10 < tagBytes.length) {
          if (majorVersion == 2) {
            if (offset + 6 >= tagBytes.length) break;
            final frameId = String.fromCharCodes(tagBytes.sublist(offset, offset + 3));
            final frameSize = (tagBytes[offset + 3] << 16) |
                              (tagBytes[offset + 4] << 8) |
                              tagBytes[offset + 5];
            offset += 6;
            if (frameId == "PIC") {
              if (offset + frameSize > tagBytes.length) break;
              final frameData = tagBytes.sublist(offset, offset + frameSize);
              if (frameData.length > 5) {
                int idx = 5;
                while (idx < frameData.length && frameData[idx] != 0) {
                  idx++;
                }
                idx++;
                if (idx < frameData.length) {
                  return Uint8List.fromList(frameData.sublist(idx));
                }
              }
              break;
            }
            offset += frameSize;
          } else {
            final frameId = String.fromCharCodes(tagBytes.sublist(offset, offset + 4));
            final frameSize = majorVersion == 4
                ? (((tagBytes[offset + 4] & 0x7F) << 21) |
                   ((tagBytes[offset + 5] & 0x7F) << 14) |
                   ((tagBytes[offset + 6] & 0x7F) << 7) |
                   (tagBytes[offset + 7] & 0x7F))
                : ((tagBytes[offset + 4] << 24) |
                   (tagBytes[offset + 5] << 16) |
                   (tagBytes[offset + 6] << 8) |
                   tagBytes[offset + 7]);
            offset += 10;
            if (frameId == "APIC") {
              if (offset + frameSize > tagBytes.length) break;
              final frameData = tagBytes.sublist(offset, offset + frameSize);
              if (frameData.length > 2) {
                final encoding = frameData[0];
                int idx = 1;
                while (idx < frameData.length && frameData[idx] != 0) {
                  idx++;
                }
                idx++;
                if (idx < frameData.length) {
                  idx++;
                  if (encoding == 1 || encoding == 2) {
                    while (idx + 1 < frameData.length && (frameData[idx] != 0 || frameData[idx + 1] != 0)) {
                      idx += 2;
                    }
                    idx += 2;
                  } else {
                    while (idx < frameData.length && frameData[idx] != 0) {
                      idx++;
                    }
                    idx++;
                  }
                  if (idx < frameData.length) {
                    return Uint8List.fromList(frameData.sublist(idx));
                  }
                }
              }
              break;
            }
            offset += frameSize;
          }
        }
      } else if (header[0] == 0x66 && header[1] == 0x4C && header[2] == 0x61 && header[3] == 0x43) {
        raf.setPositionSync(4);
        bool isLast = false;
        while (!isLast) {
          final blockHeader = raf.readSync(4);
          if (blockHeader.length < 4) break;
          isLast = (blockHeader[0] & 0x80) != 0;
          final blockType = blockHeader[0] & 0x7F;
          final blockLength = (blockHeader[1] << 16) | (blockHeader[2] << 8) | blockHeader[3];
          if (blockType == 6) {
            final blockData = raf.readSync(blockLength);
            if (blockData.length == blockLength) {
              int mimeLen = (blockData[4] << 24) | (blockData[5] << 16) | (blockData[6] << 8) | blockData[7];
              int descLen = (blockData[8 + mimeLen] << 24) | (blockData[9 + mimeLen] << 16) | (blockData[10 + mimeLen] << 8) | blockData[11 + mimeLen];
              int dataOffset = 8 + mimeLen + 4 + descLen + 16;
              if (dataOffset + 4 <= blockData.length) {
                int dataLen = (blockData[dataOffset] << 24) | (blockData[dataOffset + 1] << 16) | (blockData[dataOffset + 2] << 8) | blockData[dataOffset + 3];
                if (dataOffset + 4 + dataLen <= blockData.length) {
                  raf.closeSync();
                  return Uint8List.fromList(blockData.sublist(dataOffset + 4, dataOffset + 4 + dataLen));
                }
              }
            }
            break;
          } else {
            raf.setPositionSync(raf.positionSync() + blockLength);
          }
        }
        raf.closeSync();
      } else {
        raf.closeSync();
      }
    } catch (_) {}
    return null;
  }

  ImageProvider _getAlbumArt() {
    if (_currentTrackIndex == -1 || _playlist.isEmpty) {
      return const AssetImage('assets/cactus_pot.png');
    }
    final trackPath = _playlist[_currentTrackIndex];
    if (_cachedArtPath == trackPath) {
      if (_cachedArtBytes != null) {
        return MemoryImage(_cachedArtBytes!);
      }
    } else {
      _cachedArtPath = trackPath;
      _cachedArtBytes = _extractEmbeddedAlbumArt(trackPath);
      if (_cachedArtBytes != null) {
        return MemoryImage(_cachedArtBytes!);
      }
    }
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

  void _applyEqPreset(String preset) {
    setState(() {
      _eqPreset = preset;
      if (preset == 'Flat') {
        _eqBands[0] = 0.0; _eqBands[1] = 0.0; _eqBands[2] = 0.0; _eqBands[3] = 0.0; _eqBands[4] = 0.0;
        for (int i = 0; i < 10; i++) {
          _eq10Bands[i] = 0.0;
        }
      } else if (preset == 'Bass Booster') {
        _eqBands[0] = 6.0; _eqBands[1] = 4.0; _eqBands[2] = 0.0; _eqBands[3] = 0.0; _eqBands[4] = -2.0;
        _eq10Bands[0] = 6.0; _eq10Bands[1] = 5.5; _eq10Bands[2] = 5.0; _eq10Bands[3] = 4.0; _eq10Bands[4] = 2.0;
        _eq10Bands[5] = 0.0; _eq10Bands[6] = 0.0; _eq10Bands[7] = 0.0; _eq10Bands[8] = -1.0; _eq10Bands[9] = -2.0;
        _eqBassBoost = 80.0;
      } else if (preset == 'Treble Booster') {
        _eqBands[0] = -2.0; _eqBands[1] = 0.0; _eqBands[2] = 0.0; _eqBands[3] = 4.0; _eqBands[4] = 6.0;
        _eq10Bands[0] = -2.0; _eq10Bands[1] = -2.0; _eq10Bands[2] = -1.0; _eq10Bands[3] = 0.0; _eq10Bands[4] = 0.0;
        _eq10Bands[5] = 2.0; _eq10Bands[6] = 3.5; _eq10Bands[7] = 5.0; _eq10Bands[8] = 6.0; _eq10Bands[9] = 7.0;
        _eqTrebleBoost = 80.0;
      } else if (preset == 'Vocal Booster') {
        _eqBands[0] = -2.0; _eqBands[1] = 0.0; _eqBands[2] = 3.0; _eqBands[3] = 5.0; _eqBands[4] = 2.0;
        _eq10Bands[0] = -2.0; _eq10Bands[1] = -1.5; _eq10Bands[2] = 0.0; _eq10Bands[3] = 1.0; _eq10Bands[4] = 3.0;
        _eq10Bands[5] = 4.5; _eq10Bands[6] = 5.0; _eq10Bands[7] = 4.0; _eq10Bands[8] = 2.0; _eq10Bands[9] = 1.0;
        _eqVocalPresence = 70.0;
      } else if (preset == 'Electronic') {
        _eqBands[0] = 5.0; _eqBands[1] = 2.0; _eqBands[2] = -1.0; _eqBands[3] = 2.0; _eqBands[4] = 4.0;
        _eq10Bands[0] = 5.0; _eq10Bands[1] = 4.0; _eq10Bands[2] = 2.0; _eq10Bands[3] = 0.0; _eq10Bands[4] = -1.5;
        _eq10Bands[5] = -1.0; _eq10Bands[6] = 1.0; _eq10Bands[7] = 2.0; _eq10Bands[8] = 3.5; _eq10Bands[9] = 4.5;
      } else if (preset == 'Rock') {
        _eqBands[0] = 4.0; _eqBands[1] = 2.0; _eqBands[2] = -2.0; _eqBands[3] = 2.0; _eqBands[4] = 5.0;
        _eq10Bands[0] = 4.0; _eq10Bands[1] = 3.0; _eq10Bands[2] = 2.0; _eq10Bands[3] = -1.0; _eq10Bands[4] = -2.0;
        _eq10Bands[5] = -1.0; _eq10Bands[6] = 1.0; _eq10Bands[7] = 2.5; _eq10Bands[8] = 4.0; _eq10Bands[9] = 5.0;
      } else if (preset == 'Pop') {
        _eqBands[0] = -2.0; _eqBands[1] = -1.0; _eqBands[2] = 3.0; _eqBands[3] = 2.0; _eqBands[4] = -1.0;
        _eq10Bands[0] = -2.0; _eq10Bands[1] = -1.5; _eq10Bands[2] = -1.0; _eq10Bands[3] = 1.0; _eq10Bands[4] = 2.5;
        _eq10Bands[5] = 3.5; _eq10Bands[6] = 3.0; _eq10Bands[7] = 2.0; _eq10Bands[8] = 0.0; _eq10Bands[9] = -1.0;
      } else if (preset == 'Jazz') {
        _eqBands[0] = 3.0; _eqBands[1] = 1.0; _eqBands[2] = 1.0; _eqBands[3] = 2.0; _eqBands[4] = 2.0;
        _eq10Bands[0] = 3.0; _eq10Bands[1] = 2.5; _eq10Bands[2] = 1.5; _eq10Bands[3] = 1.0; _eq10Bands[4] = 0.5;
        _eq10Bands[5] = 1.0; _eq10Bands[6] = 1.5; _eq10Bands[7] = 2.0; _eq10Bands[8] = 2.0; _eq10Bands[9] = 2.0;
      } else if (preset == 'Classical') {
        _eqBands[0] = 4.0; _eqBands[1] = 2.0; _eqBands[2] = 0.0; _eqBands[3] = 2.0; _eqBands[4] = 4.0;
        _eq10Bands[0] = 4.0; _eq10Bands[1] = 3.5; _eq10Bands[2] = 2.0; _eq10Bands[3] = 1.0; _eq10Bands[4] = 0.0;
        _eq10Bands[5] = 0.0; _eq10Bands[6] = 1.0; _eq10Bands[7] = 2.0; _eq10Bands[8] = 3.0; _eq10Bands[9] = 4.0;
      } else if (preset == 'Dance') {
        _eqBands[0] = 6.0; _eqBands[1] = 5.0; _eqBands[2] = 0.0; _eqBands[3] = 3.0; _eqBands[4] = 5.0;
        _eq10Bands[0] = 6.0; _eq10Bands[1] = 5.5; _eq10Bands[2] = 5.0; _eq10Bands[3] = 2.0; _eq10Bands[4] = 0.0;
        _eq10Bands[5] = 0.0; _eq10Bands[6] = 2.0; _eq10Bands[7] = 3.5; _eq10Bands[8] = 5.0; _eq10Bands[9] = 5.0;
      } else if (preset == 'Club') {
        _eqBands[0] = 5.0; _eqBands[1] = 4.5; _eqBands[2] = 2.0; _eqBands[3] = 2.0; _eqBands[4] = 1.5;
        _eq10Bands[0] = 5.0; _eq10Bands[1] = 4.8; _eq10Bands[2] = 4.5; _eq10Bands[3] = 3.0; _eq10Bands[4] = 2.0;
        _eq10Bands[5] = 2.0; _eq10Bands[6] = 2.0; _eq10Bands[7] = 2.0; _eq10Bands[8] = 1.8; _eq10Bands[9] = 1.5;
      } else if (preset == 'Party') {
        _eqBands[0] = 4.0; _eqBands[1] = 4.0; _eqBands[2] = 0.0; _eqBands[3] = 0.0; _eqBands[4] = 4.0;
        _eq10Bands[0] = 4.0; _eq10Bands[1] = 4.0; _eq10Bands[2] = 2.0; _eq10Bands[3] = 0.0; _eq10Bands[4] = 0.0;
        _eq10Bands[5] = 0.0; _eq10Bands[6] = 0.0; _eq10Bands[7] = 0.0; _eq10Bands[8] = 2.0; _eq10Bands[9] = 4.0;
      } else if (preset == 'Soft') {
        _eqBands[0] = 2.0; _eqBands[1] = 1.0; _eqBands[2] = 0.0; _eqBands[3] = -1.0; _eqBands[4] = -2.0;
        _eq10Bands[0] = 2.0; _eq10Bands[1] = 1.5; _eq10Bands[2] = 1.0; _eq10Bands[3] = 0.5; _eq10Bands[4] = 0.0;
        _eq10Bands[5] = -0.5; _eq10Bands[6] = -1.0; _eq10Bands[7] = -1.5; _eq10Bands[8] = -2.0; _eq10Bands[9] = -2.0;
      } else if (preset == 'Techno') {
        _eqBands[0] = 5.0; _eqBands[1] = 3.5; _eqBands[2] = -1.0; _eqBands[3] = 3.0; _eqBands[4] = 5.0;
        _eq10Bands[0] = 5.0; _eq10Bands[1] = 4.5; _eq10Bands[2] = 3.5; _eq10Bands[3] = 1.0; _eq10Bands[4] = -1.0;
        _eq10Bands[5] = 0.0; _eq10Bands[6] = 2.5; _eq10Bands[7] = 3.0; _eq10Bands[8] = 4.5; _eq10Bands[9] = 5.0;
      } else if (_savedPresets.containsKey(preset)) {
        final pr = _savedPresets[preset]!;
        _eqIs10Band = pr['is10Band'] as bool? ?? false;
        final list5 = pr['eqBands'] as List?;
        if (list5 != null) {
          for (int i = 0; i < 5 && i < list5.length; i++) {
            _eqBands[i] = (list5[i] as num).toDouble();
          }
        }
        final list10 = pr['eq10Bands'] as List?;
        if (list10 != null) {
          for (int i = 0; i < 10 && i < list10.length; i++) {
            _eq10Bands[i] = (list10[i] as num).toDouble();
          }
        }
        _preAmpGain = (pr['preAmpGain'] as num? ?? 0.0).toDouble();
        _eqBassBoost = (pr['bassBoost'] as num? ?? 0.0).toDouble();
        _eqTrebleBoost = (pr['trebleBoost'] as num? ?? 0.0).toDouble();
        _eqVocalPresence = (pr['vocalPresence'] as num? ?? 0.0).toDouble();
        _stereoExpansion = (pr['stereoExpansion'] as num? ?? 100.0).toDouble();
        _stereoPan = (pr['stereoPan'] as num? ?? 0.0).toDouble();
        _reverbRoomSize = (pr['reverbRoomSize'] as num? ?? 0.0).toDouble();
        _reverbMix = (pr['reverbMix'] as num? ?? 0.0).toDouble();
        _limiterEnabled = pr['limiterEnabled'] as bool? ?? false;
        _limiterThreshold = (pr['limiterThreshold'] as num? ?? 0.0).toDouble();
        _limiterRatio = (pr['limiterRatio'] as num? ?? 1.0).toDouble();
        _surroundSound = pr['surroundSound'] as bool? ?? false;
      }
    });
    _applyAllDSPToPlayer();
  }

  void _applyAllDSPToPlayer() {
    if (_player == null) return;
    _player!.setPreamp(_preAmpGain);
    double bassDb = 6.0 * (_eqBassBoost / 100.0);
    double trebleDb = 6.0 * (_eqTrebleBoost / 100.0);
    double vocalDb = 6.0 * (_eqVocalPresence / 100.0);
    if (_eqIs10Band) {
      for (int i = 0; i < 10; i++) {
        double gain = _eq10Bands[i];
        if (i <= 2) {
          gain += bassDb;
        } else if (i >= 4 && i <= 6) {
          gain += vocalDb;
        } else if (i >= 7) {
          gain += trebleDb;
        }
        _player!.setEqBand(i, gain);
      }
    } else {
      for (int i = 0; i < 5; i++) {
        double gain = _eqBands[i];
        if (i == 0) {
          gain += bassDb;
        } else if (i == 1 || i == 2) {
          gain += vocalDb;
        } else if (i >= 3) {
          gain += trebleDb;
        }
        _player!.setEqBand(i * 2, gain);
        _player!.setEqBand(i * 2 + 1, gain);
      }
    }
    _player!.setStereoExpansion(_stereoExpansion);
    _player!.setStereoPan(_stereoPan);
    _player!.setReverbRoomSize(_reverbRoomSize);
    _player!.setReverbMix(_reverbMix);
    _player!.setLimiterEnabled(_limiterEnabled);
    _player!.setLimiterThreshold(_limiterThreshold);
    _player!.setLimiterRatio(_limiterRatio);
  }

  void _showCustomEqualizerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2824),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final double screenHeight = MediaQuery.of(context).size.height;
            final double height = screenHeight * 0.85;
            final List<String> allPresets = [
              'Flat',
              'Bass Booster',
              'Treble Booster',
              'Vocal Booster',
              'Electronic',
              'Rock',
              'Pop',
              'Jazz',
              'Classical',
              'Dance',
              'Club',
              'Party',
              'Soft',
              'Techno',
              ..._savedPresets.keys
            ];
            return Container(
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Custom Equalizer',
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.refresh, color: Colors.white70),
                            onPressed: () {
                              setSheetState(() {
                                _applyEqPreset('Flat');
                                _preAmpGain = 0.0;
                                _eqBassBoost = 0.0;
                                _eqTrebleBoost = 0.0;
                                _eqVocalPresence = 0.0;
                                _stereoExpansion = 100.0;
                                _stereoPan = 0.0;
                                _reverbRoomSize = 0.0;
                                _reverbMix = 0.0;
                                _limiterEnabled = false;
                                _limiterThreshold = 0.0;
                                _limiterRatio = 1.0;
                                _surroundSound = false;
                              });
                              setState(() {});
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white70),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: allPresets.contains(_eqPreset) ? _eqPreset : 'Flat',
                          dropdownColor: const Color(0xFF1E2824),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          items: allPresets.map((preset) {
                            final isCustom = _savedPresets.containsKey(preset);
                            return DropdownMenuItem<String>(
                              value: preset,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(preset),
                                  if (isCustom)
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.redAccent, size: 16),
                                      onPressed: () {
                                        setSheetState(() {
                                          _savedPresets.remove(preset);
                                          _saveCustomPresets();
                                          if (_eqPreset == preset) {
                                            _eqPreset = 'Flat';
                                            _applyEqPreset('Flat');
                                          }
                                        });
                                        setState(() {});
                                      },
                                    ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setSheetState(() {
                                _applyEqPreset(val);
                              });
                              setState(() {});
                            }
                          },
                        ),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.save, size: 16, color: Colors.white),
                        label: const Text('Save Preset', style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF698075),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _showSavePresetDialog(setSheetState),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ChoiceChip(
                        label: const Text('5 Bands'),
                        selected: !_eqIs10Band,
                        selectedColor: const Color(0xFF698075),
                        backgroundColor: const Color(0xFF2D3C35),
                        labelStyle: TextStyle(color: !_eqIs10Band ? Colors.white : Colors.white70),
                        onSelected: (selected) {
                          if (selected) {
                            setSheetState(() {
                              _eqIs10Band = false;
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 12),
                      ChoiceChip(
                        label: const Text('10 Bands'),
                        selected: _eqIs10Band,
                        selectedColor: const Color(0xFF698075),
                        backgroundColor: const Color(0xFF2D3C35),
                        labelStyle: TextStyle(color: _eqIs10Band ? Colors.white : Colors.white70),
                        onSelected: (selected) {
                          if (selected) {
                            setSheetState(() {
                              _eqIs10Band = true;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 180,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2D3C35),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _eqIs10Band 
                      ? _build10BandsControls(setSheetState) 
                      : _build5BandsControls(setSheetState),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      children: [
                        _buildSectionHeader('Enhancers'),
                        _buildFXSlider(
                          title: 'Bass Boost',
                          value: _eqBassBoost,
                          min: 0.0,
                          max: 100.0,
                          suffix: '${_eqBassBoost.round()}%',
                          onChanged: (val) {
                            setSheetState(() {
                              _eqBassBoost = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _applyAllDSPToPlayer();
                          },
                        ),
                        _buildFXSlider(
                          title: 'Treble Boost',
                          value: _eqTrebleBoost,
                          min: 0.0,
                          max: 100.0,
                          suffix: '${_eqTrebleBoost.round()}%',
                          onChanged: (val) {
                            setSheetState(() {
                              _eqTrebleBoost = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _applyAllDSPToPlayer();
                          },
                        ),
                        _buildFXSlider(
                          title: 'Vocal Clarity',
                          value: _eqVocalPresence,
                          min: 0.0,
                          max: 100.0,
                          suffix: '${_eqVocalPresence.round()}%',
                          onChanged: (val) {
                            setSheetState(() {
                              _eqVocalPresence = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _applyAllDSPToPlayer();
                          },
                        ),
                        _buildFXSlider(
                          title: 'Pre-Amp Gain',
                          value: _preAmpGain,
                          min: -15.0,
                          max: 15.0,
                          suffix: '${_preAmpGain.round()} dB',
                          onChanged: (val) {
                            setSheetState(() {
                              _preAmpGain = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setPreamp(val);
                          },
                        ),
                        _buildSectionHeader('Spatial & Room Effects'),
                        _buildFXSlider(
                          title: 'Stereo Widener',
                          value: _stereoExpansion,
                          min: 0.0,
                          max: 200.0,
                          suffix: '${_stereoExpansion.round()}%',
                          onChanged: (val) {
                            setSheetState(() {
                              _stereoExpansion = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setStereoExpansion(val);
                          },
                        ),
                        _buildFXSlider(
                          title: 'Pan Balance',
                          value: _stereoPan,
                          min: -1.0,
                          max: 1.0,
                          suffix: _stereoPan == 0.0 ? 'Center' : (_stereoPan < 0.0 ? 'L ${(_stereoPan * -100).round()}%' : 'R ${(_stereoPan * 100).round()}%'),
                          onChanged: (val) {
                            setSheetState(() {
                              _stereoPan = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setStereoPan(val);
                          },
                        ),
                        _buildFXSlider(
                          title: 'Reverb Room Size',
                          value: _reverbRoomSize,
                          min: 0.0,
                          max: 100.0,
                          suffix: '${_reverbRoomSize.round()}%',
                          onChanged: (val) {
                            setSheetState(() {
                              _reverbRoomSize = val;
                              _eqPreset = 'Custom';
                              _reverbPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setReverbRoomSize(val);
                          },
                        ),
                        _buildFXSlider(
                          title: 'Reverb Mix Level',
                          value: _reverbMix,
                          min: 0.0,
                          max: 100.0,
                          suffix: '${_reverbMix.round()}%',
                          onChanged: (val) {
                            setSheetState(() {
                              _reverbMix = val;
                              _eqPreset = 'Custom';
                              _reverbPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setReverbMix(val);
                          },
                        ),
                        SwitchListTile(
                          title: const Text('3D Surround Sound', style: TextStyle(color: Colors.white, fontSize: 14)),
                          value: _surroundSound,
                          activeColor: const Color(0xFF698075),
                          onChanged: (val) {
                            setSheetState(() {
                              _surroundSound = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setStereoExpansion(val ? 180.0 : 100.0);
                          },
                        ),
                        _buildSectionHeader('Limiter & Dynamics'),
                        SwitchListTile(
                          title: const Text('Limiter Switch', style: TextStyle(color: Colors.white, fontSize: 14)),
                          value: _limiterEnabled,
                          activeColor: const Color(0xFF698075),
                          onChanged: (val) {
                            setSheetState(() {
                              _limiterEnabled = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setLimiterEnabled(val);
                          },
                        ),
                        _buildFXSlider(
                          title: 'Limiter Threshold',
                          value: _limiterThreshold,
                          min: -20.0,
                          max: 0.0,
                          suffix: '${_limiterThreshold.round()} dB',
                          enabled: _limiterEnabled,
                          onChanged: (val) {
                            setSheetState(() {
                              _limiterThreshold = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setLimiterThreshold(val);
                          },
                        ),
                        _buildFXSlider(
                          title: 'Limiter Ratio',
                          value: _limiterRatio,
                          min: 1.0,
                          max: 20.0,
                          suffix: '${_limiterRatio.toStringAsFixed(1)}:1',
                          enabled: _limiterEnabled,
                          onChanged: (val) {
                            setSheetState(() {
                              _limiterRatio = val;
                              _eqPreset = 'Custom';
                            });
                            setState(() {});
                            _player?.setLimiterRatio(val);
                          },
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _build5BandsControls(StateSetter setSheetState) {
    final labels = ['60Hz', '230Hz', '910Hz', '4kHz', '14kHz'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(5, (index) {
        return Column(
          children: [
            Text(
              '${_eqBands[index].round()}dB',
              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: const Color(0xFF698075),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: const Color(0xFFB5A296),
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: _eqBands[index],
                    min: -12.0,
                    max: 12.0,
                    onChanged: (val) {
                      setSheetState(() {
                        _eqBands[index] = val;
                        _eqPreset = 'Custom';
                      });
                      setState(() {});
                      _player?.setEqBand(index * 2, val);
                      _player?.setEqBand(index * 2 + 1, val);
                    },
                  ),
                ),
              ),
            ),
            Text(
              labels[index],
              style: const TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.w600),
            ),
          ],
        );
      }),
    );
  }

  Widget _build10BandsControls(StateSetter setSheetState) {
    final labels = ['31Hz', '62Hz', '125Hz', '250Hz', '500Hz', '1kHz', '2kHz', '4kHz', '8kHz', '16kHz'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(10, (index) {
          return SizedBox(
            width: 48,
            child: Column(
              children: [
                Text(
                  '${_eq10Bands[index].round()}',
                  style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold),
                ),
                Expanded(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: const Color(0xFF698075),
                        inactiveTrackColor: Colors.white24,
                        thumbColor: const Color(0xFFB5A296),
                        trackHeight: 1.5,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      ),
                      child: Slider(
                        value: _eq10Bands[index],
                        min: -12.0,
                        max: 12.0,
                        onChanged: (val) {
                          setSheetState(() {
                            _eq10Bands[index] = val;
                            _eqPreset = 'Custom';
                          });
                          setState(() {});
                          _player?.setEqBand(index, val);
                        },
                      ),
                    ),
                  ),
                ),
                Text(
                  labels[index],
                  style: const TextStyle(fontSize: 8, color: Colors.white70, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0, bottom: 8.0, left: 8.0),
      child: Text(
        title,
        style: const TextStyle(color: Color(0xFFB5A296), fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5),
      ),
    );
  }

  Widget _buildFXSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    required String suffix,
    required ValueChanged<double> onChanged,
    bool enabled = true,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF2D3C35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: enabled ? Colors.white : Colors.white38, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(suffix, style: TextStyle(color: enabled ? const Color(0xFFB5A296) : Colors.white24, fontSize: 11, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: const Color(0xFF698075),
                inactiveTrackColor: Colors.white12,
                thumbColor: const Color(0xFFB5A296),
                trackHeight: 3,
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSavePresetDialog(StateSetter setSheetState) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2824),
          title: const Text('Save Custom Preset', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Preset name...',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFB5A296))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  setSheetState(() {
                    _savedPresets[name] = {
                      'is10Band': _eqIs10Band,
                      'eqBands': List<double>.from(_eqBands),
                      'eq10Bands': List<double>.from(_eq10Bands),
                      'preAmpGain': _preAmpGain,
                      'bassBoost': _eqBassBoost,
                      'trebleBoost': _eqTrebleBoost,
                      'vocalPresence': _eqVocalPresence,
                      'stereoExpansion': _stereoExpansion,
                      'stereoPan': _stereoPan,
                      'reverbRoomSize': _reverbRoomSize,
                      'reverbMix': _reverbMix,
                      'limiterEnabled': _limiterEnabled,
                      'limiterThreshold': _limiterThreshold,
                      'limiterRatio': _limiterRatio,
                      'surroundSound': _surroundSound,
                    };
                    _eqPreset = name;
                    _saveCustomPresets();
                  });
                  setState(() {});
                }
                Navigator.pop(context);
              },
              child: const Text('Save', style: TextStyle(color: Color(0xFFB5A296))),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEqualizerBandsRow() {
    final labels = ['60Hz', '230Hz', '910Hz', '4kHz', '14kHz'];
    return Container(
      height: 160,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(5, (index) {
          return Column(
            children: [
              Text(
                '${_eqBands[index].round()}dB',
                style: const TextStyle(fontSize: 10, color: Color(0xFF1E2824), fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: const Color(0xFF698075),
                      inactiveTrackColor: Colors.grey[300],
                      thumbColor: const Color(0xFF698075),
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: _eqBands[index],
                      min: -12.0,
                      max: 12.0,
                      onChanged: _customEqEnabled
                          ? (val) {
                              setState(() {
                                _eqBands[index] = val;
                                _eqPreset = 'Custom';
                              });
                              _player?.setEqBand(index * 2, val);
                              _player?.setEqBand(index * 2 + 1, val);
                            }
                          : null,
                    ),
                  ),
                ),
              ),
              Text(
                labels[index],
                style: const TextStyle(fontSize: 10, color: Color(0xFF698075), fontWeight: FontWeight.w600),
              ),
            ],
          );
        }),
      ),
    );
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
                  value: ['System Default Device', 'Built-in Speaker', 'Headphones', 'Bluetooth Device', _detectedDeviceName].contains(_audioOutputDevice) ? _audioOutputDevice : 'System Default Device',
                  items: ['System Default Device', 'Built-in Speaker', 'Headphones', 'Bluetooth Device', if (_detectedDeviceName != 'Detecting...') _detectedDeviceName],
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
                _buildSettingsDropdownTile(
                  title: 'Preset',
                  value: _savedPresets.containsKey(_eqPreset) || ['Flat', 'Bass Booster', 'Vocal Booster', 'Electronic', 'Rock', 'Pop', 'Jazz', 'Classical', 'Custom'].contains(_eqPreset) ? _eqPreset : 'Flat',
                  items: ['Flat', 'Bass Booster', 'Vocal Booster', 'Electronic', 'Rock', 'Pop', 'Jazz', 'Classical', 'Custom', ..._savedPresets.keys],
                  onChanged: (val) {
                    if (val != null) {
                      _applyEqPreset(val);
                    }
                  },
                ),
                const SizedBox(height: 8),
                _buildSettingsSwitchTile(
                  title: 'Custom Equalizer Mode',
                  value: _customEqEnabled,
                  onChanged: (val) {
                    setState(() {
                      _customEqEnabled = val;
                      if (!val) {
                        _eqPreset = 'Flat';
                        _applyEqPreset('Flat');
                      } else {
                        _applyAllDSPToPlayer();
                      }
                    });
                  },
                ),
                const SizedBox(height: 8),
                _buildEqualizerBandsRow(),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F3F1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Custom Equalizer',
                            style: TextStyle(color: Color(0xFF1E2824), fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Configure 10-band EQ & effects',
                            style: TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF698075),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _showCustomEqualizerSheet,
                        child: const Text('Configure', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _buildSettingsHeader('Advanced Sound Effects'),
                _buildSettingsSliderTile(
                  title: 'Pre-Amp Gain (${_preAmpGain.round()} dB)',
                  value: _preAmpGain,
                  min: -15.0,
                  max: 15.0,
                  onChanged: (val) {
                    setState(() {
                      _preAmpGain = val;
                    });
                    _player?.setPreamp(val);
                  },
                ),
                _buildSettingsSliderTile(
                  title: 'Stereo Expansion (${_stereoExpansion.round()}%)',
                  value: _stereoExpansion,
                  min: 0.0,
                  max: 200.0,
                  onChanged: (val) {
                    setState(() {
                      _stereoExpansion = val;
                    });
                    _player?.setStereoExpansion(val);
                  },
                ),
                _buildSettingsDropdownTile(
                  title: 'Reverb Room Preset',
                  value: ['None', 'Room', 'Studio', 'Concert Hall', 'Cathedral', 'Custom'].contains(_reverbPreset) ? _reverbPreset : 'None',
                  items: ['None', 'Room', 'Studio', 'Concert Hall', 'Cathedral', 'Custom'],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _reverbPreset = val;
                        if (val == 'None') {
                          _reverbRoomSize = 0.0;
                          _reverbMix = 0.0;
                        } else if (val == 'Room') {
                          _reverbRoomSize = 30.0;
                          _reverbMix = 25.0;
                        } else if (val == 'Studio') {
                          _reverbRoomSize = 15.0;
                          _reverbMix = 15.0;
                        } else if (val == 'Concert Hall') {
                          _reverbRoomSize = 75.0;
                          _reverbMix = 60.0;
                        } else if (val == 'Cathedral') {
                          _reverbRoomSize = 95.0;
                          _reverbMix = 80.0;
                        }
                      });
                      _player?.setReverbRoomSize(_reverbRoomSize);
                      _player?.setReverbMix(_reverbMix);
                    }
                  },
                ),
                _buildSettingsSwitchTile(
                  title: '3D Surround Sound',
                  value: _surroundSound,
                  onChanged: (val) {
                    setState(() {
                      _surroundSound = val;
                      _stereoExpansion = val ? 180.0 : 100.0;
                    });
                    _player?.setStereoExpansion(val ? 180.0 : 100.0);
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsHeader('About'),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F3F1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Music Player 3',
                        style: TextStyle(color: Color(0xFF1E2824), fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'This application was built within 12 hours with the help of a fully functional IDE called Antigravity by me [Kaji]. Make sure to use it.',
                        style: TextStyle(color: Color(0xFF698075), fontSize: 12, height: 1.4),
                      ),
                      SizedBox(height: 10),
                      Text(
                        'Developed with Flutter and Rust Audio Engine.',
                        style: TextStyle(color: Colors.grey, fontSize: 11, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Center(
                  child: Text(
                    'Music Player 3 v1.0.0',
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
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
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
    double min = 0.0,
    double max = 1.0,
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
                min: min,
                max: max,
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
                  clipBehavior: Clip.none,
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
                          child: Transform.translate(
                            offset: const Offset(0, -4.5),
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
                    _currentTrackIndex != -1 ? p.basenameWithoutExtension(_playlist[_currentTrackIndex]).toUpperCase() : 'SELECT A SONG',
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
                        _currentTrackIndex != -1 ? 'Local Audio' : 'No Active Track',
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
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: List.generate(35, (index) {
                                final isActive = _durationMs > 0 && (_positionMs / _durationMs * 35) > index;
                                return Container(
                                  width: 2,
                                  height: _waveHeights[index],
                                  decoration: BoxDecoration(
                                    color: isActive ? Colors.black : Colors.black.withOpacity(0.4),
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
