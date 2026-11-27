import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'image_cache.dart' show isValidImageBytes;

const _avatarMaxSide = 512;

/// 将头像原图缩放到最大边 [_avatarMaxSide] px 并压缩编码，避免相册 12 MP 原图直接落盘与 Base64 同步。
/// 优先走原生 `flutter_image_compress`，不支持或失败时回退到 `dart:ui` 缩图编码；若仍失败返回 null 由调用方回退原文件拷贝。
@visibleForTesting
Future<({Uint8List bytes, String ext})?> resizeAvatarBytes(Uint8List raw) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? desc;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(raw);
    desc = await ui.ImageDescriptor.encoded(buffer);
    final w = desc.width;
    final h = desc.height;
    if (w <= 0 || h <= 0) return null;
    final longest = math.max(w, h);
    final scale = longest > _avatarMaxSide ? _avatarMaxSide / longest : 1.0;
    final dstW = math.max(1, (w * scale).round());
    final dstH = math.max(1, (h * scale).round());
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        final mobile = Platform.isAndroid || Platform.isIOS;
        final out = await FlutterImageCompress.compressWithList(
          raw,
          minWidth: dstW,
          minHeight: dstH,
          quality: 88,
          format: mobile ? CompressFormat.webp : CompressFormat.jpeg,
        );
        if (out.isNotEmpty && isValidImageBytes(out)) {
          return (bytes: out, ext: mobile ? '.webp' : '.jpg');
        }
      } catch (_) {}
    }
    if (scale >= 1.0 && raw.length <= 256 << 10) return null;
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await desc.instantiateCodec(targetWidth: dstW, targetHeight: dstH);
      image = (await codec.getNextFrame()).image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        final png = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
        if (png.isNotEmpty && isValidImageBytes(png)) {
          return (bytes: png, ext: '.png');
        }
      }
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    desc?.dispose();
    buffer?.dispose();
  }
  return null;
}

/// 自己选的头像：只保存在本机（wenku8 的头像要在网站上改，这里不改网站上的）。
class _AvatarController extends Notifier<String?> {
  @override
  String? build() => Hive.box('session').get('avatar') as String?;

  Future<void> pick() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    final src = file?.path;
    if (src == null) return;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'avatar'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    ({Uint8List bytes, String ext})? resized;
    try {
      resized = await resizeAvatarBytes(await File(src).readAsBytes());
    } catch (_) {}
    final File dest;
    if (resized != null) {
      dest = File(p.join(dir.path, 'avatar_$stamp${resized.ext}'));
      await dest.writeAsBytes(resized.bytes, flush: true);
    } else {
      dest = await File(src).copy(p.join(dir.path, 'avatar_$stamp${p.extension(src)}'));
    }
    await Hive.box('session').putAll({'avatar': dest.path, 'avatar:ts': DateTime.now().millisecondsSinceEpoch});
    state = dest.path;
  }

  Future<void> clear() async {
    await Hive.box('session').delete('avatar');
    await Hive.box('session').put('avatar:ts', DateTime.now().millisecondsSinceEpoch);
    state = null;
  }
}

final avatarProvider = NotifierProvider<_AvatarController, String?>(_AvatarController.new);
