// Mendocino Remote Connectivity branding.
//
// Kept in its own file so the shared pages need only a one-line hook each, and so a brand
// change touches one place. The mark is vector (assets/mendocino_mark.svg), so it stays
// crisp at any scale factor.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const String kMendocinoAsset = 'assets/mendocino_mark.svg';
const String kMendocinoWordmark = 'Mendocino-Apcela';
const String kMendocinoTagline = 'Remote Session';
const String kMendocinoDeveloper = 'Developed by Manuj';

/// Brand lockup for the top-left of the connection page: mark, wordmark, tagline.
class MendocinoHeader extends StatelessWidget {
  const MendocinoHeader({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).textTheme.bodyMedium?.color;
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        SvgPicture.asset(kMendocinoAsset, width: 22, height: 19),
        const SizedBox(width: 8),
        Text(
          kMendocinoWordmark,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: onSurface,
          ),
        ),
        Container(
          width: 1,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          color: onSurface?.withOpacity(0.25),
        ),
        Flexible(
          child: Text(
            kMendocinoTagline,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: onSurface?.withOpacity(0.6),
            ),
          ),
        ),
      ],
    );
  }
}

/// Developer credit for the bottom-right. Deliberately low-contrast: it should be
/// legible without competing with the controls around it.
class MendocinoDeveloperCredit extends StatelessWidget {
  const MendocinoDeveloperCredit({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Text(
        kMendocinoDeveloper,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.45),
        ),
      ),
    );
  }
}
