import 'dart:io';

/// 先写到旁边的临时文件，写完再改名换上：写到一半被杀掉、磁盘满了，原来的位置不会留下半个文件（同一目录内改名是原子的）。
Future<void> writeFileAtomic(File file, List<int> bytes) async {
  final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}
