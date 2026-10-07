// "Check for update" button.
//
// Upstream has no manual update check on desktop at all — only a background check every
// 24h that quietly sets a URL, plus a passive card on the home page. That means a user who
// wants to know whether they are current has no way to ask, and an administrator pushing a
// fix cannot tell a user to go and fetch it.
//
// This drives the same backend as the automatic check (main_get_software_update_url ->
// do_check_software_update -> mrc_update::check_github_release), so there is one code path
// and one source of truth; the button only makes it reachable on demand.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:get/get.dart';

import '../desktop/widgets/update_progress.dart';
import '../models/platform_model.dart';
import '../models/state_model.dart';

class MrcCheckUpdateButton extends StatefulWidget {
  const MrcCheckUpdateButton({Key? key}) : super(key: key);

  @override
  State<MrcCheckUpdateButton> createState() => _MrcCheckUpdateButtonState();
}

class _MrcCheckUpdateButtonState extends State<MrcCheckUpdateButton> {
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);

    // The check is asynchronous and reports back by setting stateGlobal.updateUrl, so
    // record what it was first — otherwise a URL left over from the periodic check would
    // be mistaken for this run's result.
    final before = stateGlobal.updateUrl.value;
    stateGlobal.updateUrl.value = '';

    bind.mainGetSoftwareUpdateUrl();

    // Poll briefly rather than waiting a fixed interval, so a fast answer feels fast and
    // a slow network still gets a verdict instead of a false "up to date".
    var found = '';
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (stateGlobal.updateUrl.value.isNotEmpty) {
        found = stateGlobal.updateUrl.value;
        break;
      }
    }
    if (found.isEmpty && before.isNotEmpty) {
      // Restore: the check may simply not have completed in our window.
      stateGlobal.updateUrl.value = before;
    }

    if (!mounted) return;
    setState(() => _busy = false);

    final version = await bind.mainGetVersion();
    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(found.isEmpty ? 'No update available' : 'Update available'),
        content: Text(
          found.isEmpty
              ? 'You are running the latest version ($version).'
              : 'A newer version is available.\n\n'
                  'Installing will download it from the release page and replace this\n'
                  'installation. You may be asked to authenticate.',
        ),
        actions: [
          if (found.isNotEmpty)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(found)),
              child: const Text('Release notes'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(found.isEmpty ? 'OK' : 'Not now'),
          ),
          // Reuses upstream's download-with-progress-and-install flow rather than
          // reimplementing it, so there is a single install path.
          if (found.isNotEmpty)
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                handleUpdate(found);
              },
              child: const Text('Install now'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _busy ? null : _check,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ).marginOnly(right: 6),
          Text(
            _busy ? 'Checking...' : 'Check for update',
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
        ],
      ).marginSymmetric(vertical: 4.0),
    );
  }
}
