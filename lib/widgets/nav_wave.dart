import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Change these values to adjust both the navbar silhouette and its outline.
class NavWave {
  NavWave._();

  static const double height = 10;
  static const double amplitude = 5;
  static const double wavelength = 100;
  static const double strokeWidth = 2;

  static double y(double x) =>
      height / 2 + amplitude * math.sin(x * 2 * math.pi / wavelength);

  /// Edge in the supplied coordinate space, sampled from the same origin for
  /// both the clipping path and the painted outline.
  static Path edgePath(Size size, {double inset = 0}) {
    final top = size.height - height;
    final path = Path()..moveTo(0, top + y(0) - inset);
    for (var x = 2.0; x < size.width; x += 2) {
      path.lineTo(x, top + y(x) - inset);
    }
    return path..lineTo(size.width, top + y(size.width) - inset);
  }
}

class NavWaveClipper extends CustomClipper<Path> {
  const NavWaveClipper({this.topEdge = false});

  final bool topEdge;

  @override
  Path getClip(Size size) {
    if (topEdge) {
      return NavWave.edgePath(Size(size.width, NavWave.height))
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
    }
    return NavWave.edgePath(size)
      ..lineTo(size.width, 0)
      ..lineTo(0, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant NavWaveClipper oldClipper) =>
      topEdge != oldClipper.topEdge;
}

class NavWavePainter extends CustomPainter {
  const NavWavePainter({this.topEdge = false});

  final bool topEdge;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      NavWave.edgePath(
        topEdge ? Size(size.width, NavWave.height) : size,
        inset: topEdge ? -NavWave.strokeWidth / 2 : NavWave.strokeWidth / 2,
      ),
      Paint()
        ..color = AppColors.accent
        ..strokeWidth = NavWave.strokeWidth
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant NavWavePainter oldDelegate) =>
      topEdge != oldDelegate.topEdge;
}
