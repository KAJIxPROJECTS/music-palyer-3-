import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class Win32FilePicker {
  static String? pickFile() {
    const int bufferSize = 4096;
    final ofn = calloc<OPENFILENAME>();
    final szFile = calloc<Uint16>(bufferSize);
    szFile.asTypedList(bufferSize).fillRange(0, bufferSize, 0);
    ofn.ref.lStructSize = sizeOf<OPENFILENAME>();
    ofn.ref.hwndOwner = GetActiveWindow();
    ofn.ref.lpstrFile = szFile.cast<Utf16>() as PWSTR;
    ofn.ref.nMaxFile = bufferSize;
    final filter = 'Audio Files (*.mp3;*.wav;*.ogg;*.flac)\x00*.mp3;*.wav;*.ogg;*.flac\x00All Files (*.*)\x00*.*\x00\x00';
    final filterPtr = filter.toNativeUtf16();
    ofn.ref.lpstrFilter = filterPtr.cast<Utf16>() as PWSTR;
    ofn.ref.nFilterIndex = 1;
    ofn.ref.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST | OFN_EXPLORER;
    try {
      if (GetOpenFileName(ofn)) {
        return szFile.cast<Utf16>().toDartString();
      }
    } catch (_) {
    } finally {
      calloc.free(filterPtr);
      calloc.free(szFile);
      calloc.free(ofn);
    }
    return null;
  }
}
