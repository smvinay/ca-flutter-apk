
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class StackedBarPainter extends CustomPainter {
  final List<int> segments;
  final List<Color> colors;
  final double animationValue; // 0..1
  final int maxTotal;
  final double scale;
  final double borderRadius;

  StackedBarPainter({
    required this.segments,
    required this.colors,
    required this.animationValue,
    required this.maxTotal,
    required this.scale,
    this.borderRadius = 6.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    final height = size.height;
    final barTop = height * 0.15;
    final barHeight = height * 0.7;
    final fullWidth = size.width * animationValue.clamp(0.0, 1.0);

    // background track
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, barTop, size.width, barHeight),
      Radius.circular(borderRadius),
    );
    final bgPaint = Paint()..color = Colors.grey.shade200;
    canvas.drawRRect(bgRect, bgPaint);

    // nothing to draw
    if (maxTotal <= 0 || (segments.every((v) => v == 0))) return;

    final denom =
    maxTotal > 0 ? maxTotal : segments.fold<int>(1, (p, e) => p + e);
    double x = 0.0;

    // find first and last non-zero indices so we round only ends
    int firstIdx = -1;
    int lastIdx = -1;
    for (int i = 0; i < segments.length; i++) {
      if (segments[i] > 0) {
        if (firstIdx == -1) firstIdx = i;
        lastIdx = i;
      }
    }

    for (var i = 0; i < segments.length; i++) {
      final segVal = segments[i];
      if (segVal <= 0) continue;
      final frac = segVal / denom;
      final segWidth = fullWidth * frac;
      if (segWidth <= 0) continue;

      // corner radii only at overall start/end segments
      Radius tl = Radius.zero,
          bl = Radius.zero,
          tr = Radius.zero,
          br = Radius.zero;
      if (i == firstIdx) {
        tl = Radius.circular(borderRadius);
        bl = Radius.circular(borderRadius);
      }
      if (i == lastIdx) {
        tr = Radius.circular(borderRadius);
        br = Radius.circular(borderRadius);
      }

      final rrect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, barTop, segWidth, barHeight),
        topLeft: tl,
        bottomLeft: bl,
        topRight: tr,
        bottomRight: br,
      );

      paint.color = colors[i];
      canvas.drawRRect(rrect, paint);

      // ----------------------------
      // ALWAYS draw the value INSIDE the segment
      // Scale font down until it fits (down to minFont).
      // Then center horizontally & vertically.
      // ----------------------------
      final valueText = segVal.toString();

      // Start font size depending on scale
      double fontSize = 12.0 * scale;
      final double minFontSize = 7.0 * scale;
      TextPainter tp = _textPainter(valueText, fontSize, Colors.white);

      // Layout with an unconstrained width first to measure natural width
      tp.layout();

      // We'll reserve a small padding inside segment
      const double paddingInside = 6.0;

      // If the text doesn't fit, reduce fontSize until it fits or reaches minFontSize
      while ((tp.width + paddingInside) > segWidth && fontSize > minFontSize) {
        fontSize -= 0.6 * scale;
        tp = _textPainter(valueText, fontSize, Colors.white);
        tp.layout();
      }

      // If still wider than segWidth (extremely small segment), we still draw it centered;
      // it will be clipped visually — this avoids drawing it above the bar per your request.
      final dx = x + max(0.0, (segWidth - tp.width) / 2);
      final dy = barTop + (barHeight - tp.height) / 2;
      tp.paint(canvas, Offset(dx, dy));

      x += segWidth;
    }
  }

  TextPainter _textPainter(String text, double fontSize, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '',
    );
    // layout will be called by caller when needed
    return tp;
  }

  @override
  bool shouldRepaint(covariant StackedBarPainter old) {
    return old.animationValue != animationValue ||
        !listEquals(old.segments, segments) ||
        old.maxTotal != maxTotal ||
        old.scale != scale;
  }
}
