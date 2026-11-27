part of '../characters_page.dart';

/// 添加 / 编辑人物与设定词条弹窗。
class _CharacterEditorSheet extends ConsumerStatefulWidget {
  const _CharacterEditorSheet({required this.aid, this.initial, required this.catalogue});

  final String aid;
  final BookCharacter? initial;
  final List<CatVolume> catalogue;

  @override
  ConsumerState<_CharacterEditorSheet> createState() => _CharacterEditorSheetState();
}

class _CharacterEditorSheetState extends ConsumerState<_CharacterEditorSheet> {
  static final _aliasSplitRe = RegExp(r'[,，/、]');

  late final TextEditingController _name = TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _orig = TextEditingController(text: widget.initial?.originalName ?? '');
  late final TextEditingController _aliasInput = TextEditingController();
  late final TextEditingController _summary = TextEditingController(text: widget.initial?.summary ?? '');
  late final TextEditingController _cnSummary = TextEditingController(text: widget.initial?.cnSummary ?? '');
  late final TextEditingController _note = TextEditingController(text: widget.initial == null ? '' : BookCharacters.noteOf(widget.initial!));
  late final List<String> _aliases = List<String>.of(widget.initial?.aliases ?? const []);
  late String _role = widget.initial?.role ?? CharacterRole.support;
  late int _color = widget.initial?.color ?? _pickNextColor();
  late bool _highlight = widget.initial == null ? true : BookCharacters.isHighlightActive(widget.initial!);
  late int _spoilerVol = widget.initial?.spoilerVol ?? 0;
  late final String _avatarUrl = widget.initial?.avatarUrl ?? '';
  late String _localAvatar = widget.initial?.localAvatar ?? '';
  Uint8List? _pendingAvatarBytes;
  String? _nameError;

  int _pickNextColor() {
    final used = {for (final c in BookCharacters.of(widget.aid)) c.color};
    return characterHighlightColors.firstWhere((c) => !used.contains(c), orElse: () => characterHighlightColors.first);
  }

  @override
  void dispose() {
    _name.dispose();
    _orig.dispose();
    _aliasInput.dispose();
    _summary.dispose();
    _cnSummary.dispose();
    _note.dispose();
    super.dispose();
  }

  void _addAlias() {
    final raw = _aliasInput.text.trim();
    if (raw.isEmpty) return;
    for (final part in raw.split(_aliasSplitRe)) {
      final t = part.trim();
      if (t.isNotEmpty && t != _name.text.trim() && !_aliases.contains(t)) {
        _aliases.add(t);
      }
    }
    _aliasInput.clear();
    setState(() {});
  }

  Future<void> _pickLocalAvatar() async {
    if (kIsWeb) return;
    final picked = await FilePicker.pickFile(type: FileType.image);
    final path = picked?.path;
    if (path == null || !mounted) return;
    final bytes = await File(path).readAsBytes();
    if (!mounted) return;
    await _cropAndSaveAvatar(bytes);
  }

  Future<void> _pickBookIllustrationAvatar() async {
    if (kIsWeb) return;
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => _BookIllustrationPickerPage(aid: widget.aid, catalogue: widget.catalogue)),
    );
    if (url == null || !mounted) return;
    try {
      final bytes = await ref.read(imageStoreProvider).load(url);
      if (!mounted) return;
      await _cropAndSaveAvatar(bytes);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载图片失败：$e')));
    }
  }

  Future<void> _cropAndSaveAvatar(Uint8List rawBytes) async {
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => _AvatarCropPage(bytes: rawBytes)),
    );
    if (cropped == null || !mounted) return;
    // 先暂存在内存中，仅在点击保存时真正落盘，防止取消编辑后留下孤儿文件
    setState(() => _pendingAvatarBytes = cropped);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请输入名称');
      return;
    }
    if (_aliasInput.text.trim().isNotEmpty) _addAlias();
    final oldLocal = widget.initial?.localAvatar ?? '';
    final base = widget.initial ?? BookCharacter(id: '', aid: widget.aid, name: name);
    var targetLocalAvatar = _localAvatar;
    if (_pendingAvatarBytes != null && _pendingAvatarBytes!.isNotEmpty) {
      final key = base.id.isNotEmpty ? base.id : 'new';
      targetLocalAvatar = await BookCharacters.saveLocalAvatar(key, _pendingAvatarBytes!);
    }
    try {
      await BookCharacters.upsert(
        base.copyWith(
          name: name,
          originalName: _orig.text.trim(),
          aliases: _aliases,
          role: _role,
          avatarUrl: _avatarUrl,
          localAvatar: targetLocalAvatar,
          summary: _summary.text.trim(),
          cnSummary: _cnSummary.text.trim(),
          spoilerVol: _spoilerVol,
          color: _color,
        ),
        enableHighlight: _highlight,
        note: _note.text,
      );
    } catch (_) {
      if (targetLocalAvatar.isNotEmpty && targetLocalAvatar != oldLocal) {
        await BookCharacters.deleteLocalAvatar(targetLocalAvatar);
      }
      rethrow;
    }
    if (oldLocal.isNotEmpty && oldLocal != targetLocalAvatar) {
      await BookCharacters.deleteLocalAvatar(oldLocal);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final init = widget.initial;
    if (init == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${init.name}」？'),
        content: const Text('将同时移除该人物绑定的正文高亮与笔记。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await BookCharacters.delete(widget.aid, init.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewChar = BookCharacter(
      id: widget.initial?.id ?? '',
      aid: widget.aid,
      name: _name.text.trim().isEmpty ? '人物' : _name.text.trim(),
      avatarUrl: _avatarUrl,
      localAvatar: _localAvatar,
      color: _color,
    );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(widget.initial == null ? '添加人物 / 设定' : '编辑人物 / 设定', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (widget.initial != null)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: _delete,
                      child: const Text('删除'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _CharacterAvatar(char: previewChar, size: 60, allowPreview: false, previewBytes: _pendingAvatarBytes),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (!kIsWeb) ...[
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: _pickBookIllustrationAvatar,
                            icon: const Icon(Icons.photo_library_outlined, size: 16),
                            label: const Text('书内插图裁剪'),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: _pickLocalAvatar,
                            icon: const Icon(Icons.upload_outlined, size: 16),
                            label: const Text('本地选图裁剪'),
                          ),
                        ],
                        if (_localAvatar.isNotEmpty || _pendingAvatarBytes != null)
                          TextButton(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: () => setState(() {
                              _localAvatar = '';
                              _pendingAvatarBytes = null;
                            }),
                            child: const Text('清除自定头像'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                onChanged: (_) => setState(() => _nameError = null),
                decoration: InputDecoration(label: const Text('显示名称（中文名）'), errorText: _nameError),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _orig,
                decoration: const InputDecoration(label: Text('原名（可选，如日文名）')),
              ),
              const SizedBox(height: 12),
              XSegments<String>(
                title: '定位',
                value: _role,
                options: const {CharacterRole.main: '主角', CharacterRole.support: '配角', CharacterRole.setting: '设定'},
                onChanged: (v) => setState(() => _role = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _aliasInput,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addAlias(),
                      decoration: const InputDecoration(label: Text('添加别名 / 昵称'), hint: Text('支持用逗号分隔多个', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _addAlias, child: const Text('添加')),
                ],
              ),
              AppCollapse(
                visible: _aliases.isNotEmpty,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final a in _aliases)
                        InputChip(
                          label: Text(a),
                          onDeleted: () => setState(() => _aliases.remove(a)),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开启正文高亮'),
                subtitle: const Text('在阅读器中自动高亮名称与所有别名，点按弹出人物卡'),
                value: _highlight,
                onChanged: (v) => setState(() => _highlight = v),
              ),
              AppCollapse(
                visible: _highlight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ColorPickerField(
                    color: _color,
                    highlight: true,
                    sample: _name.text.trim().isEmpty ? '人物名' : _name.text.trim(),
                    onChanged: (c) => setState(() => _color = c),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('防剧透卷号'),
                        Text(
                          _spoilerVol == 0 ? '不折叠个人笔记' : '读到第 $_spoilerVol 卷前折叠个人笔记',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: hz(context, '减少卷号'),
                    onPressed: _spoilerVol <= 0 ? null : () => setState(() => _spoilerVol--),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(_spoilerVol == 0 ? '关' : '第$_spoilerVol卷', textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
                  ),
                  IconButton(
                    tooltip: hz(context, '增加卷号'),
                    onPressed: () => setState(() => _spoilerVol++),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _cnSummary,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(label: Text('中文简介（萌娘百科/自填，可选）')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _summary,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(label: Text('原简介（Bangumi，可选）')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(label: Text('个人笔记（与高亮备注互通）')),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _save,
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 从本书已缓存插图和卷封面中挑选一张图片用于裁剪人物头像。
class _BookIllustrationPickerPage extends ConsumerStatefulWidget {
  const _BookIllustrationPickerPage({required this.aid, required this.catalogue});

  final String aid;
  final List<CatVolume> catalogue;

  @override
  ConsumerState<_BookIllustrationPickerPage> createState() => _BookIllustrationPickerPageState();
}

class _BookIllustrationPickerPageState extends ConsumerState<_BookIllustrationPickerPage> {
  late final Future<List<String>> _images = _collectCachedImages();

  Future<List<String>> _collectCachedImages() async {
    final urls = <String>{};
    for (final v in widget.catalogue) {
      for (final c in v.chapters) {
        if (!ChapterCache.has(widget.aid, c.cid)) continue;
        final Content? content = await ChapterCache.get(widget.aid, c.cid);
        if (content != null) {
          for (final u in content.images) {
            if (u.isNotEmpty) urls.add(u);
          }
        }
      }
    }
    for (final u in Volumes.covers(widget.aid).values) {
      final clean = splitCrop(u).url;
      if (clean.isNotEmpty) urls.add(clean);
    }
    return urls.toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('从本书插图选择')),
      body: FutureBuilder<List<String>>(
        future: _images,
        builder: (context, snap) => AppCrossfade(
          fill: true,
          child: !snap.hasData
              ? const Center(key: ValueKey('loading'), child: CircularProgressIndicator())
              : snap.data!.isEmpty
              ? Center(
                  key: const ValueKey('empty'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('暂无已缓存的本书插图。\n阅读过插图章节或缓存本书后即可在此选择。', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                )
              : GridView.builder(
                  key: const ValueKey('grid'),
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.78),
                  itemCount: snap.data!.length,
                  itemBuilder: (context, i) => AppPressScale(
                    scale: 0.96,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(context, snap.data![i]),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: ColoredBox(
                          color: scheme.surfaceContainer,
                          child: NetImage(snap.data![i], fit: BoxFit.cover, thumbnail: true, decodeSize: const Size(140, 180), maxDecodeWidth: 480),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 1:1 方形头像裁剪页：拖动、双指缩放框选头像，导出 256×256 PNG 字节。
class _AvatarCropPage extends StatefulWidget {
  const _AvatarCropPage({required this.bytes});

  final Uint8List bytes;

  @override
  State<_AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<_AvatarCropPage> {
  final _tc = TransformationController();
  late final Future<ui.Size> _imgSize = imageSize(widget.bytes);
  Size? _laidOut;
  bool _saving = false;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  static Size _fill(double w, double h, double box) {
    final s = math.max(box / w, box / h);
    return Size(w * s, h * s);
  }

  Future<void> _confirm(ui.Size imgSize, double box) async {
    if (_saving) return;
    setState(() => _saving = true);
    ui.Codec? codec;
    ui.Image? img;
    ui.Picture? picture;
    ui.Image? outImg;
    var popped = false;
    try {
      codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      final child = _fill(imgSize.width, imgSize.height, box);
      final scale = _tc.value.getMaxScaleOnAxis();
      final t = _tc.value.getTranslation();
      final left = (-t.x / scale / child.width).clamp(0.0, 1.0);
      final top = (-t.y / scale / child.height).clamp(0.0, 1.0);
      final width = (box / scale / child.width).clamp(0.01, 1.0 - left);
      final height = (box / scale / child.height).clamp(0.01, 1.0 - top);

      final src = Rect.fromLTWH(left * img.width, top * img.height, width * img.width, height * img.height);
      const outSize = 256;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(img, src, const Rect.fromLTWH(0, 0, 256, 256), Paint()..filterQuality = FilterQuality.high);
      picture = recorder.endRecording();
      outImg = await picture.toImage(outSize, outSize);
      final data = await outImg.toByteData(format: ui.ImageByteFormat.png);
      if (mounted && data != null) {
        popped = true;
        Navigator.pop(context, data.buffer.asUint8List());
      }
    } catch (_) {
    } finally {
      outImg?.dispose();
      picture?.dispose();
      img?.dispose();
      codec?.dispose();
      if (!popped && mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('裁剪头像', style: TextStyle(color: Colors.white)),
    ),
    body: FutureBuilder<ui.Size>(
      future: _imgSize,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('无法解码该图片', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('返回')),
              ],
            ),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final imgSize = snap.data!;
        final previewCacheW = math.min(imgSize.width.round(), 1440);
        return LayoutBuilder(
          builder: (context, c) {
            final box = math.min(c.maxWidth - 48, c.maxHeight - 120).clamp(160.0, 320.0);
            final frame = Size(box, box);
            final child = _fill(imgSize.width, imgSize.height, box);
            if (_laidOut != frame) {
              _laidOut = frame;
              _tc.value = Matrix4.translationValues((box - child.width) / 2, (box - child.height) / 2, 0);
            }
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: SizedBox.fromSize(
                      size: frame,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          InteractiveViewer(
                            transformationController: _tc,
                            constrained: false,
                            minScale: 1,
                            maxScale: 6,
                            clipBehavior: Clip.none,
                            child: SizedBox.fromSize(
                              size: child,
                              child: Image.memory(widget.bytes, fit: BoxFit.fill, cacheWidth: previewCacheW > 0 ? previewCacheW : null),
                            ),
                          ),
                          IgnorePointer(child: CustomPaint(size: frame, painter: _SquareFramePainter())),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Row(
                    children: [
                      const Expanded(child: Text('拖动、双指缩放框选头像区域', style: TextStyle(color: Colors.white70, fontSize: 13))),
                      FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
                        onPressed: _saving ? null : () => _confirm(imgSize, box),
                        child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('完成'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    ),
  );
}

class _SquareFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final frame = Offset.zero & size;
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(frame.inflate(4000))
        ..addRRect(RRect.fromRectAndRadius(frame, Radius.circular(size.width * 0.24))),
      Paint()..color = Colors.black.withValues(alpha: 0.65),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, Radius.circular(size.width * 0.24)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
