import 'dart:io';
import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart';

class TinyBertClassifier {
  OrtSession? _session;
  bool _initialized = false;
  bool _downloading = false;

  bool get isReady => _initialized;
  bool get isDownloading => _downloading;

  Future<void> init() async {
    if (_initialized || _downloading) return;
    final file = File('tinybert.onnx');
    if (!await file.exists()) {
      _downloading = true;
      try {
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(
          'https://huggingface.co/onnx-community/TinyBERT-finetuned-NER-ONNX/resolve/main/onnx/model.onnx'
        ));
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>([], (p, e) => p..addAll(e));
          await file.writeAsBytes(bytes);
        }
      } catch (_) {}
      _downloading = false;
    }

    if (await file.exists()) {
      try {
        OrtEnv.instance.init();
        final options = OrtSessionOptions();
        _session = OrtSession.fromFile(file, options);
        _initialized = true;
      } catch (_) {}
    }
  }

  Future<List<double>?> runInference(String text) async {
    if (!_initialized || _session == null) return null;
    try {
      final words = text.toLowerCase().split(RegExp(r'\s+'));
      final Map<String, int> vocab = {
        'play': 2505,
        'pause': 9811,
        'stop': 2408,
        'next': 2393,
        'prev': 10839,
        'loop': 6551,
        'status': 2726,
        'scan': 8953,
        'info': 5374,
        'help': 2279,
      };
      final List<int> inputIds = [101];
      for (final word in words) {
        if (word.isEmpty) continue;
        inputIds.add(vocab[word] ?? 100);
      }
      inputIds.add(102);
      while (inputIds.length < 16) {
        inputIds.add(0);
      }
      final finalInputIds = inputIds.sublist(0, 16);
      final attentionMask = List<int>.generate(16, (i) => i < inputIds.length ? 1 : 0);
      final tokenTypeIds = List<int>.generate(16, (_) => 0);

      final shape = [1, 16];
      final inputIdsTensor = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(finalInputIds),
        shape,
      );
      final attentionMaskTensor = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(attentionMask),
        shape,
      );
      final tokenTypeIdsTensor = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(tokenTypeIds),
        shape,
      );

      final inputs = {
        'input_ids': inputIdsTensor,
        'attention_mask': attentionMaskTensor,
        'token_type_ids': tokenTypeIdsTensor,
      };

      final runOptions = OrtRunOptions();
      final outputs = await _session!.runAsync(runOptions, inputs);

      List<double>? result;
      if (outputs != null && outputs.isNotEmpty) {
        final firstOutput = outputs[0];
        if (firstOutput != null && firstOutput is OrtValueTensor) {
          final rawValue = firstOutput.value;
          if (rawValue is List) {
            result = _flattenDoubleList(rawValue);
          }
        }
      }

      runOptions.release();
      inputIdsTensor.release();
      attentionMaskTensor.release();
      tokenTypeIdsTensor.release();
      if (outputs != null) {
        for (final out in outputs) {
          out?.release();
        }
      }

      return result;
    } catch (_) {
      return null;
    }
  }

  List<double> _flattenDoubleList(List list) {
    final List<double> result = [];
    for (final element in list) {
      if (element is List) {
        result.addAll(_flattenDoubleList(element));
      } else if (element is double) {
        result.add(element);
      } else if (element is num) {
        result.add(element.toDouble());
      }
    }
    return result;
  }

  void dispose() {
    _session?.release();
    _session = null;
    _initialized = false;
  }
}
