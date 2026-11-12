import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_prefs.dart';
import '../sync.dart';
import '../widgets.dart';
import '../x_list.dart';
import '../text.dart';

/// 同步设置：坚果云（或其他 WebDAV）。应用密码在坚果云网页端"账户信息 → 安全选项 → 第三方应用管理"里生成。
class SyncPage extends ConsumerStatefulWidget {
  const SyncPage({super.key});

  @override
  ConsumerState<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends ConsumerState<SyncPage> {
  final _url = TextEditingController(text: Sync.url);
  final _user = TextEditingController(text: Sync.user);
  final _pass = TextEditingController();
  final _folder = TextEditingController(text: Sync.folder);
  String? _note;
  bool _busy = false;
  bool _showPass = false;
  bool _passLoaded = false; // 安全存储里的密码读出来之前不能保存，否则会用空密码把它覆盖掉

  @override
  void initState() {
    super.initState();
    Sync.password().then((p) {
      if (mounted) _pass.text = p;
    }).catchError((_) {}).whenComplete(() {
      if (mounted) setState(() => _passLoaded = true);
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _save() => Sync.save(url: _url.text, user: _user.text, pass: _pass.text, folder: _folder.text);

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await _save();
      await Sync.test();
      _note = '连接成功';
    } catch (e) {
      _note = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 导出：把本机数据存成一个 JSON 交给系统分享（发给自己、存到文件都行）。
  Future<void> _export() async {
    final file = File('${(await getTemporaryDirectory()).path}/ark_novel_backup.json');
    await file.writeAsString(jsonEncode(Sync.snapshot()));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  /// 导入：选一个导出的 JSON，按同步规则并入本机（不会覆盖）。
  Future<void> _import() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
      if (picked == null) return;
      final merged = await Sync.importBackup(utf8.decode(await File(picked.path!).readAsBytes()));
      if (!mounted) return;
      setState(() => _note = merged ? '已导入备份' : '这是本机导出的备份，不需要导入');
    } catch (e) {
      if (mounted) setState(() => _note = '导入失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncProvider);
    ref.watch(appPrefsProvider);
    final prefs = ref.read(appPrefsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final last = Sync.lastSync;
    final busy = _busy || status.busy || !_passLoaded;
    final lastText = last > 0 ? '上次同步：${'${DateTime.fromMillisecondsSinceEpoch(last)}'.split('.').first.substring(0, 16)}' : '尚未同步';
    // 顶上一块状态卡：图标、是否已配置、上次同步时间；测试 / 同步的结果也显示在这里
    final message = _note ?? status.message;
    final card = Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          XLeading(icon: Sync.configured ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, color: Sync.configured ? scheme.primary : null),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Sync.configured ? '已配置 WebDAV 同步' : '未配置同步', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(lastText, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                if (message != null) ...[const SizedBox(height: 6), Text(message, style: TextStyle(fontSize: 13, height: 1.4, color: message == '连接成功' ? scheme.primary : scheme.onSurface))],
              ],
            ),
          ),
        ],
      ),
    );
    Widget field(TextEditingController c, String label, IconData icon, {String? helper, bool secret = false, TextInputType? type}) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: TextField(
        controller: c,
        obscureText: secret && !_showPass,
        enableInteractiveSelection: true,
        autocorrect: false,
        keyboardType: type,
        decoration: InputDecoration(
          label: Text(label),
          helper: helper == null ? null : Text(helper),
          helperMaxLines: 2,
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: secret
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: hz(context, '粘贴'),
                      icon: const Icon(Icons.content_paste_outlined, size: 19),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        final t = data?.text?.trim();
                        if (t != null && t.isNotEmpty) {
                          c.text = t;
                          c.selection = TextSelection.collapsed(offset: t.length);
                        }
                      },
                    ),
                    IconButton(
                      tooltip: hz(context, _showPass ? '隐藏密码' : '显示密码'),
                      icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 19),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                  ],
                )
              : null,
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('同步')),
      body: contentWidth(ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          card,
          const XDivider(),
          const XGroupTitle('WebDAV 账号'),
          field(_url, 'WebDAV 地址', Icons.link, type: TextInputType.url),
          field(_user, '账号', Icons.person_outline, helper: '坚果云填写注册邮箱'),
          field(_pass, '应用密码', Icons.key_outlined, secret: true, helper: '不是登录密码。坚果云在网页端「账户信息 → 安全选项 → 第三方应用管理」中生成'),
          field(_folder, '同步文件夹', Icons.folder_outlined, helper: '将在 WebDAV 根目录下自动创建'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: busy ? null : _test, child: const Text('测试连接'))),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await _save();
                            await ref.read(syncProvider.notifier).run();
                          },
                    child: status.busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('立即同步'),
                  ),
                ),
              ],
            ),
          ),
          const XDivider(),
          const XGroupTitle('可选同步项'),
          XSwitch(
            title: '同步自定义头像',
            value: prefs.get(P.syncAvatar, true),
            onChanged: (v) => prefs.set(P.syncAvatar, v),
          ),
          XSwitch(
            title: '同步书架与更新偏好',
            value: prefs.get(P.syncShelfPrefs, false),
            onChanged: (v) => prefs.set(P.syncShelfPrefs, v),
          ),
          XSwitch(
            title: '同步阅读器设置',
            value: prefs.get(P.syncReaderPrefs, false),
            onChanged: (v) => prefs.set(P.syncReaderPrefs, v),
          ),
          XSwitch(
            title: '同步外观与主题',
            value: prefs.get(P.syncAppearance, false),
            onChanged: (v) => prefs.set(P.syncAppearance, v),
          ),
          const XDivider(),
          const XGroupTitle('手动备份'),
          XTile(leading: const XLeading(icon: Icons.upload_outlined), title: '导出同步数据', onTap: _export),
          XTile(leading: const XLeading(icon: Icons.download_outlined), title: '导入同步数据', subtitle: '合并到本机，不覆盖', onTap: _import),
        ],
      )),
    );
  }
}
