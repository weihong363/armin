import 'package:flutter/material.dart';

class ArminScrollBehavior extends MaterialScrollBehavior {
  const ArminScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ArminScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }
}

class ArminScrollPhysics extends ClampingScrollPhysics {
  const ArminScrollPhysics({super.parent});

  @override
  double? get dragStartDistanceMotionThreshold => null;

  @override
  ArminScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return ArminScrollPhysics(parent: buildParent(ancestor));
  }
}
