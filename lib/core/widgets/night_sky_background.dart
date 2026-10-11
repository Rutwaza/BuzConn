import 'dart:math' as math;

import 'package:flutter/material.dart';

class NightSkyBackground extends StatefulWidget {
  const NightSkyBackground({super.key});

  @override
  State<NightSkyBackground> createState() => _NightSkyBackgroundState();
}

class _NightSkyBackgroundState extends State<NightSkyBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 90),
    )..repeat();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }

    return RepaintBoundary(
      child: CustomPaint(
        painter: _NightSkyPainter(_controller),
        size: Size.infinite,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.radius,
    required this.phase,
    required this.cycles,
  });

  final double x;
  final double y;
  final double radius;
  final double phase;
  final double cycles;
}

class _NightSkyPainter extends CustomPainter {
  _NightSkyPainter(this.animation) : super(repaint: animation);

  static final List<_Star> _stars = List<_Star>.generate(190, (index) {
    final random = math.Random(index + 73);
    return _Star(
      x: random.nextDouble(),
      y: random.nextDouble(),
      radius: 0.35 + random.nextDouble() * 1.2,
      phase: random.nextDouble() * math.pi * 2,
      cycles: 2 + random.nextDouble() * 7,
    );
  });

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF050817),
            Color(0xFF0B1530),
            Color(0xFF10152B),
          ],
          stops: [0, 0.58, 1],
        ).createShader(bounds),
    );

    final progress = animation.value;
    for (final star in _stars) {
      final twinkle =
          (math.sin(progress * math.pi * 2 * star.cycles + star.phase) + 1) / 2;
      final opacity = 0.16 + twinkle * 0.7;
      canvas.drawCircle(
        Offset(star.x * size.width, star.y * size.height),
        star.radius * (0.8 + twinkle * 0.35),
        Paint()..color = Color.fromRGBO(218, 231, 255, opacity),
      );
    }

    final orbitAngle = progress * math.pi * 2;
    final orbitCenter = Offset(size.width * 0.73, size.height * 0.31);
    final orbitRadiusX = size.width * 0.105;
    final orbitRadiusY = size.height * 0.12;
    final orbitBounds = Rect.fromCenter(
      center: orbitCenter,
      width: orbitRadiusX * 2,
      height: orbitRadiusY * 2,
    );
    canvas.drawOval(
      orbitBounds,
      Paint()
        ..color = const Color(0x197F9DCC)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final moonCenter = Offset(
      orbitCenter.dx + math.cos(orbitAngle) * orbitRadiusX,
      orbitCenter.dy + math.sin(orbitAngle) * orbitRadiusY,
    );
    final glowBounds = Rect.fromCircle(center: moonCenter, radius: 52);
    canvas.drawCircle(
      moonCenter,
      52,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x407F9DCC), Color(0x007F9DCC)],
        ).createShader(glowBounds),
    );

    const moonRadius = 19.0;
    final moonPath = Path()
      ..moveTo(moonCenter.dx, moonCenter.dy - moonRadius)
      ..cubicTo(
        moonCenter.dx + moonRadius * 1.2,
        moonCenter.dy - moonRadius * 0.75,
        moonCenter.dx + moonRadius * 1.2,
        moonCenter.dy + moonRadius * 0.75,
        moonCenter.dx,
        moonCenter.dy + moonRadius,
      )
      ..cubicTo(
        moonCenter.dx - moonRadius * 0.55,
        moonCenter.dy + moonRadius * 0.55,
        moonCenter.dx - moonRadius * 0.55,
        moonCenter.dy - moonRadius * 0.55,
        moonCenter.dx,
        moonCenter.dy - moonRadius,
      )
      ..close();
    canvas.drawPath(moonPath, Paint()..color = const Color(0xFFE6EDFF));
  }

  @override
  bool shouldRepaint(_NightSkyPainter oldDelegate) =>
      oldDelegate.animation != animation;
}
