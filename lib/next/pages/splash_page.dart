import 'package:flutter/material.dart' hide Text;
import '../text.dart';

/// 启动页：短暂检查登录状态。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(borderRadius: BorderRadius.circular(24), child: Image.asset('assets/images/logo.png', height: 96)),
                const SizedBox(height: 24),
                Text('Ark Novel', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 32),
                SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: theme.colorScheme.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
