import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Auto-scrolling single-line text that loops continuously (marquee style).
/// Long-press to pause (hold) and release to resume.
/// NOTE: will auto-scroll ONLY when the text actually overflows the available width.
class AutoScrollingText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final double scale;
  final double pauseAtEndsMillis; // kept but unused for continuous loop
  final double pixelsPerSecond; // scroll speed
  final double leadingGap; // extra gap appended at end before looping

  const AutoScrollingText({
    Key? key,
    required this.text,
    this.style,
    this.scale = 1.0,
    this.pauseAtEndsMillis = 600,
    this.pixelsPerSecond = 40,
    this.leadingGap = 30.0,
  }) : super(key: key);

  @override
  _AutoScrollingTextState createState() => _AutoScrollingTextState();
}

class _AutoScrollingTextState extends State<AutoScrollingText> {
  final ScrollController _ctrl = ScrollController();
  Timer? _restartTimer;
  bool _scrolling = false;
  bool _paused = false;
  double _maxScroll = 0.0;

  // measurement
  final GlobalKey _textKey = GlobalKey();
  double _singleItemWidth = 0.0;
  double _contentWidth = 0.0;
  int _repeatCount = 1; // default 1 — only increase when overflow detected

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void didUpdateWidget(covariant AutoScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.leadingGap != widget.leadingGap ||
        oldWidget.pixelsPerSecond != widget.pixelsPerSecond ||
        oldWidget.scale != widget.scale) {
      _stopScrolling();
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
    } else {
      // layout might still change (e.g., parent resized)
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
    }
  }

  void _maybeStart() {
    if (!mounted) return;
    try {
      final RenderBox? rb = _textKey.currentContext?.findRenderObject() as RenderBox?;
      final double textWidth = rb?.size.width ?? 0.0;
      // If controller has clients, use its viewportDimension, else fallback to context size
      final double viewportWidth = (_ctrl.hasClients && _ctrl.position.hasViewportDimension)
          ? _ctrl.position.viewportDimension
          : (context.size?.width ?? 0.0);

      final double effectiveViewport = viewportWidth > 0 ? viewportWidth : (context.size?.width ?? 0.0);
      _singleItemWidth = textWidth + widget.leadingGap;

      if (_singleItemWidth <= 0 || effectiveViewport <= 0) {
        // measurement not ready — try again shortly
        Future.delayed(const Duration(milliseconds: 80), () {
          if (mounted) _maybeStart();
        });
        return;
      }

      // Decide overflow: if a single text (plus gap) is wider than viewport => overflow
      final bool isOverflowing = _singleItemWidth > effectiveViewport + 1.0;

      if (!isOverflowing) {
        // No overflow: show single item, don't scroll
        _repeatCount = 1;
        _contentWidth = _singleItemWidth;
        _maxScroll = 0.0;
        _stopScrolling(); // ensure any running scroll is stopped
        setState(() {}); // rebuild to reflect repeatCount = 1
        return;
      }

      // Overflow case: repeat enough times to create seamless continuous loop
      _repeatCount = math.max(2, (effectiveViewport / _singleItemWidth).ceil() + 2);
      _contentWidth = _singleItemWidth * _repeatCount;
      _maxScroll = math.max(0.0, _contentWidth - effectiveViewport);

      if (_maxScroll > 2.0) {
        if (!_scrolling) _startLooping();
      } else {
        _stopScrolling();
      }
      setState(() {}); // rebuild if repeat count changed
    } catch (_) {
      Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) _maybeStart();
      });
    }
  }

  Future<void> _startLooping() async {
    if (!mounted) return;
    if (_scrolling || _maxScroll <= 0) return;
    _scrolling = true;

    // short initial delay to let layout stabilize
    await Future.delayed(const Duration(milliseconds: 150));

    while (mounted && _scrolling) {
      if (_paused) {
        // while paused just wait briefly and re-check
        await Future.delayed(const Duration(milliseconds: 120));
        continue;
      }

      if (!_ctrl.hasClients) {
        await Future.delayed(const Duration(milliseconds: 80));
        continue;
      }

      final double startOffset = _ctrl.offset;
      final double distance = _maxScroll - startOffset;
      if (distance <= 0.5) {
        // if already at end, jump to start
        try {
          _ctrl.jumpTo(0.0);
        } catch (_) {}
        continue;
      }

      final int durationMs = math.max(80, (distance / widget.pixelsPerSecond * 1000).toInt());

      try {
        await _ctrl.animateTo(
          _maxScroll,
          duration: Duration(milliseconds: durationMs),
          curve: Curves.linear,
        );
      } catch (_) {
        // animation interrupted or canceled
      }

      if (!mounted) break;
      if (_paused) continue;

      // Jump back to 0.0 to maintain marquee continuity (row contains repeated text)
      try {
        _ctrl.jumpTo(0.0);
      } catch (_) {}
      // immediately continue loop — no pause to emulate <marquee>
    }
  }

  void _stopScrolling() {
    _restartTimer?.cancel();
    _restartTimer = null;
    _scrolling = false;
    _paused = false;
    try {
      if (_ctrl.hasClients) _ctrl.jumpTo(0.0);
    } catch (_) {}
  }

  void _pause() {
    setState(() => _paused = true);
    try {
      _ctrl.animateTo(_ctrl.offset, duration: Duration.zero, curve: Curves.linear);
    } catch (_) {}
  }

  void _resume() {
    if (!_paused) return;
    setState(() => _paused = false);
    if (!_scrolling && _maxScroll > 0) _startLooping();
  }

  @override
  void dispose() {
    _stopScrolling();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double textHeight = (widget.style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14) *
        widget.scale *
        1.3;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => _pause(),
      onLongPressEnd: (_) => _resume(),
      onTap: () {
        if (_paused) {
          _resume();
        } else {
          _pause();
        }
      },
      child: SizedBox(
        height: textHeight,
        child: ClipRect(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(
                _repeatCount,
                    (i) => Container(
                  key: i == 0 ? _textKey : null, // measure only the first
                  padding: EdgeInsets.only(right: widget.leadingGap),
                  child: Text(
                    widget.text,
                    style: widget.style,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
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
