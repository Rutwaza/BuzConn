import 'package:flutter/material.dart';

class WindowsAuthLayout extends StatelessWidget {
  const WindowsAuthLayout({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.form,
    required this.footerPrompt,
    required this.footerAction,
    required this.onFooterTap,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget form;
  final String footerPrompt;
  final String footerAction;
  final VoidCallback onFooterTap;

  static const _ink = Color(0xFF101827);
  static const _muted = Color(0xFF68758A);
  static const _blue = Color(0xFF1769AA);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08111F),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF101D33), Color(0xFF08111F)],
                ),
              ),
            ),
          ),
          Positioned(
            top: -130,
            right: -80,
            child: _GlowOrb(
                color: const Color(0xFF1B71B9).withValues(alpha: 0.16)),
          ),
          Positioned(
            bottom: -180,
            left: -100,
            child: _GlowOrb(
                color: const Color(0xFF7B61FF).withValues(alpha: 0.12)),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: constraints.maxWidth >= 600 ? 32 : 20,
                    vertical: 24,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 350),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(child: _compactBrand()),
                          _formPanel(context),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandPanel() {
    return Container(
      height: 700,
      padding: const EdgeInsets.fromLTRB(54, 48, 48, 48),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF142944), Color(0xFF111A2A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _brandMark(),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_rounded,
                    size: 15, color: Color(0xFF77C6FF)),
                SizedBox(width: 8),
                Text(
                  'BUSINESS, BUILT AROUND PEOPLE',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    letterSpacing: 1.15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Make your next\nconnection count.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 42,
              height: 1.12,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.3,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Discover local businesses, meet new customers, and keep every conversation moving in one place.',
            style: TextStyle(
              color: Color(0xFFB5C3D7),
              fontSize: 16,
              height: 1.65,
            ),
          ),
          const SizedBox(height: 34),
          _feature(Icons.storefront_rounded, 'Find the right people',
              'Explore services and businesses around you.'),
          const SizedBox(height: 20),
          _feature(Icons.forum_rounded, 'Build real connections',
              'Start conversations and grow your network.'),
          const SizedBox(height: 20),
          _feature(Icons.trending_up_rounded, 'Grow with Duhuze',
              'Share your work with a community that cares.'),
          const Spacer(),
          const Text(
            'One place for discovery, conversations, and growth.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _compactBrand() => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: _brandMark(),
      );

  Widget _brandMark() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(
              'assets/images/duhuze_logo.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          'Duhuze',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 23,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  Widget _feature(IconData icon, String title, String description) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: const Color(0xFF77C6FF), size: 21),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(description,
                  style: const TextStyle(
                      color: Color(0xFF9FAEC3), fontSize: 12, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _formPanel(BuildContext context) {
    final theme = Theme.of(context);
    final lightTheme = theme.copyWith(
      brightness: Brightness.light,
      textTheme: theme.textTheme.apply(
        bodyColor: _ink,
        displayColor: _ink,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Theme(
        data: lightTheme,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              eyebrow.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _blue,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _ink,
                fontSize: 25,
                height: 1.15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, height: 1.5, fontSize: 14),
            ),
            const SizedBox(height: 18),
            form,
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    footerPrompt,
                    style: const TextStyle(color: _muted, fontSize: 13),
                    textAlign: TextAlign.right,
                  ),
                ),
                TextButton(
                  onPressed: onFooterTap,
                  child: Text(
                    footerAction,
                    style: const TextStyle(
                      color: _blue,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: 360,
          height: 360,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      );
}
