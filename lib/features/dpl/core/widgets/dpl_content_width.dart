import 'package:flutter/material.dart';

/// Keeps a screen's content to a phone-to-tablet width.
///
/// These screens are designed for a phone or a rugged handheld first. On a
/// desktop browser or a landscape tablet they used to stretch edge to edge —
/// a scan field nearly two thousand pixels wide, and a card's buttons a long
/// way from the text they act on. Below [maxWidth] this does nothing at all.
class DplContentWidth extends StatelessWidget {
  const DplContentWidth({super.key, required this.child, this.maxWidth = 720});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
