import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The ECM-AI logo image (ECM, the ai robot, "Powered by HeurAi").
const brandLogoAsset = 'assets/images/ecm_ai_logo.png';

/// The ai robot alone, cut from the logo (square, transparent).
const brandMarkAsset = 'assets/images/ecm_ai_mark.png';

/// The ECM-AI logo, [size] high. With [wordmark] false just the robot.
/// In dark mode it sits on a white rounded plate, as the navy "ECM" would
/// not show on the dark background.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 36, this.wordmark = true});

  final double size;
  final bool wordmark;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      wordmark ? brandLogoAsset : brandMarkAsset,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: AppTheme.appName,
    );
    if (!wordmark || Theme.of(context).brightness == Brightness.light) return image;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: size * 0.3, vertical: size * 0.12),
        child: image,
      ),
    );
  }
}
