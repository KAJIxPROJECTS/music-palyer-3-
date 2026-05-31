import re

with open('mini_chatbox_ai/lib/main.dart', 'r', encoding='utf-8') as f:
    code = f.read()

# 1. Imports
code = code.replace("import 'package:onnxruntime/onnxruntime.dart';\n", "")
code = code.replace("import 'tinybert_classifier.dart';\n", "")

# 2. OrtEnv init
ort_init = '''  try {
    OrtEnv.instance.init();
  } catch (e) {
    debugPrint("Failed to initialize ONNX Runtime: ");
  }
'''
code = code.replace(ort_init, "")

# 3. Variables
var_block = '''  final TinyBertClassifier _bertClassifier = TinyBertClassifier();
  String? _lastAIQuestion;
'''
code = code.replace(var_block, "")

chat_vars = '''  final List<Map<String, dynamic>> _chatMessages = [
    {
      'isUser': false,
      'text': "Hi! I am your AI Music Assistant. Ask me to 'play', 'pause', 'stop', 'next', 'prev', 'loop', or 'status'!",
      'time': DateTime.now()
    }
  ];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
'''
code = code.replace(chat_vars, "")

# 4. initState
init_bert = '''    _bertClassifier.init().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
'''
code = code.replace(init_bert, "")

# 5. dispose
code = code.replace("    _chatController.dispose();\n", "")
code = code.replace("    _chatScrollController.dispose();\n", "")
code = code.replace("    _bertClassifier.dispose();\n", "")

# 6. Chat Logic (from _handleSendChatMessage down to before _formatDuration)
code = re.sub(r'  void _handleSendChatMessage\(\) \{.*?\n  \}\n\n(?=  String _formatDuration)', '', code, flags=re.DOTALL)

# 7. Chat View Widget
code = re.sub(r'  Widget _buildChatView\(\) \{.*?\n  \}\n\n(?=  Widget _buildPlayerView)', '', code, flags=re.DOTALL)

# 8. Navigation Logic
nav_logic = '''    } else if (_navigationIndex == 2) {
      cardContent = _buildChatView();
    } else {'''
code = code.replace(nav_logic, "    } else {")

icon_button = '''                      IconButton(
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
'''
code = code.replace(icon_button, "")

with open('mini_chatbox_ai/lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(code)
