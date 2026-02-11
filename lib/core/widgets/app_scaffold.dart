import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppScaffold extends ConsumerWidget {
  final Widget body;
  final String? title;
  final bool showAppBar;
  final bool showBackButton;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Color? backgroundColor;
  final bool showBottomNavBar;
  final int selectedIndex;
  final void Function(int)? onTabChanged;

  const AppScaffold({
    super.key,
    required this.body,
    this.title,
    this.showAppBar = true,
    this.showBackButton = true,
    this.actions,
    this.floatingActionButton,
    this.backgroundColor,
    this.showBottomNavBar = false,
    this.selectedIndex = 0,
    this.onTabChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: backgroundColor ?? Colors.white,
      appBar: showAppBar
          ? AppBar(
              title: title != null
                  ? Text(
                      title!,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
              leading: showBackButton
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                    )
                  : null,
              actions: actions,
              elevation: 0,
              backgroundColor: Colors.white,
            )
          : null,
      body: SafeArea(
        child: body,
      ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: showBottomNavBar
          ? BottomNavigationBar(
              currentIndex: selectedIndex,
              onTap: onTabChanged,
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.home),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.message),
                  label: 'Messages',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            )
          : null,
    );
  }
}