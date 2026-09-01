import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../components/xs_bottom_nav.dart';
import 'chat_screen.dart';
import 'dashboard_screen.dart';
import 'lung_sound_screen.dart';
import 'summary_screen.dart';

/// Root tab shell with neumorphic floating nav.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _items = [
    XSNavItem(icon: Icons.dashboard_outlined, label: 'Home'),
    XSNavItem(icon: Icons.chat_bubble_outline, label: 'Chat'),
    XSNavItem(icon: Icons.graphic_eq, label: 'Sound'),
    XSNavItem(icon: Icons.assignment_outlined, label: 'Summary'),
  ];

  final _pages = const [
    DashboardScreen(),
    ChatScreen(),
    LungSoundScreen(),
    SummaryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: KeyedSubtree(
            key: ValueKey(_index),
            child: _pages[_index],
          ),
        ),
      ),
      bottomNavigationBar: XSBottomNav(
        currentIndex: _index,
        items: _items,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}
