import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Smooth EMIS loading animation. The character's travel is interpolated every
/// frame by Flutter; artwork poses are cross-faded to avoid abrupt pose cuts.
class EmisStudentAnimation extends StatefulWidget {
  final bool celebrateAtEnd;
  const EmisStudentAnimation({super.key, this.celebrateAtEnd = false});

  @override
  State<EmisStudentAnimation> createState() => _EmisStudentAnimationState();
}

class _EmisStudentAnimationState extends State<EmisStudentAnimation>
    with SingleTickerProviderStateMixin {
  static const int _poseCount = 26;
  static const String _posePath = 'assets/animations/student_poses/';

  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 9200),
  )..repeat();

  @override
  void didUpdateWidget(covariant EmisStudentAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.celebrateAtEnd && !oldWidget.celebrateAtEnd) {
      _clock.stop();
    } else if (!widget.celebrateAtEnd && oldWidget.celebrateAtEnd) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _clock,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final p = widget.celebrateAtEnd ? 1.0 : _clock.value;

            // Reserve a small final hold; each jump is E -> M -> I -> S.
            final travel = widget.celebrateAtEnd
                ? 1.0
                : (p / .92).clamp(0.0, 1.0).toDouble();
            final int segment = (travel * 3).floor().clamp(0, 2).toInt();
            final local = travel >= 1 ? 1.0 : (travel * 3) - segment;
            final letterWidth = width / 4;
            final fromX = letterWidth * (segment + .5);
            final toX = letterWidth * (segment + 1.5);
            final eased = Curves.easeInOutCubic.transform(local);
            final x = widget.celebrateAtEnd
                ? letterWidth * 3.5
                : fromX + (toX - fromX) * eased;

            // Smooth parabolic jump with anticipation and landing squash.
            final arc = widget.celebrateAtEnd ? 0.0 : math.sin(math.pi * local).abs();
            final jumpHeight = math.min(height * .38, 72.0) * arc;
            final int activeIndex = widget.celebrateAtEnd ? 3 : (local < .82 ? segment : segment + 1);

            // Cross-fade adjacent pose artwork. Position/arc remain continuously
            // interpolated, so the character does not teleport between letters.
            final poseProgress = widget.celebrateAtEnd
                ? (_poseCount - 1).toDouble()
                : (p * (_poseCount - 1)).clamp(0.0, _poseCount - 1.0).toDouble();
            final int poseIndex = poseProgress.floor().clamp(0, _poseCount - 1).toInt();
            final int nextPoseIndex = math.min(poseIndex + 1, _poseCount - 1).toInt();
            final fade = widget.celebrateAtEnd
                ? 0.0
                : Curves.easeInOut.transform((poseProgress - poseIndex).clamp(0.0, 1.0));

            // Keep character proportional on both compact and tall layouts.
            final poseWidth = math.min(letterWidth * 1.30, 104.0);
            final poseHeight = math.min(height * .78, 164.0);
            final poseLeft = (x - poseWidth / 2)
                .clamp(0.0, math.max(0.0, width - poseWidth))
                .toDouble();
            final poseBottom = 43.0 + jumpHeight;

            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _letter('E', const Color(0xFF079FE8), activeIndex == 0, height),
                          _letter('M', const Color(0xFF8744EC), activeIndex == 1, height),
                          _letter('I', const Color(0xFFFF9F0A), activeIndex == 2, height),
                          _letter('S', const Color(0xFFEF348E), activeIndex == 3, height),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: poseLeft,
                  bottom: poseBottom,
                  width: poseWidth,
                  height: poseHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        '$_posePath${_frameName(poseIndex)}',
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomCenter,
                        filterQuality: FilterQuality.high,
                        gaplessPlayback: true,
                      ),
                      if (nextPoseIndex != poseIndex)
                        Opacity(
                          opacity: fade,
                          child: Image.asset(
                            '$_posePath${_frameName(nextPoseIndex)}',
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomCenter,
                            filterQuality: FilterQuality.high,
                            gaplessPlayback: true,
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.celebrateAtEnd) ...[
                  Positioned(top: 3, right: 12, child: _sparkle(22)),
                  Positioned(top: 18, left: 20, child: _sparkle(16)),
                  Positioned(top: 9, left: width * .52, child: _sparkle(14)),
                ],
              ],
            );
          },
        ),
      );

  String _frameName(int index) => 'frame_${(index + 1).toString().padLeft(2, '0')}.png';

  Widget _sparkle(double size) => Icon(
        Icons.auto_awesome,
        size: size,
        color: const Color(0xFFFFD54F),
      );

  Widget _letter(String value, Color color, bool active, double availableHeight) {
    final h = (active ? 72.0 : 62.0)
        .clamp(52.0, math.max(52.0, availableHeight * .42))
        .toDouble();
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          height: h,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(color, Colors.white, .32)!,
                color,
                Color.lerp(color, Colors.black, .12)!,
              ],
            ),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: Colors.white.withOpacity(active ? .65 : .22),
              width: active ? 1.6 : .7,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(active ? .62 : .28),
                blurRadius: active ? 19 : 8,
                spreadRadius: active ? 2 : 0,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 39,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
