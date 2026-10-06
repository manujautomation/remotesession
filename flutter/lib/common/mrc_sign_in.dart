// Mendocino Remote Connectivity — operator sign-in, and the gate connect() calls.
//
// Kept out of common.dart so the hook there stays a single line (upstream AGENTS.md asks
// for thin hooks in shared files).

import 'package:flutter/material.dart';

import 'mrc_broker_client.dart';
import '../desktop/widgets/mendocino_branding.dart';

/// Prompts for broker credentials. Returns true once signed in.
Future<bool> mrcShowSignIn(BuildContext context) async {
  final userCtl = TextEditingController();
  final passCtl = TextEditingController();
  final totpCtl = TextEditingController();
  final keyCtl = TextEditingController();

  var useBreakglass = false;
  var busy = false;
  String? error;

  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> submit() async {
          setState(() {
            busy = true;
            error = null;
          });
          final err = useBreakglass
              ? await MrcBroker.instance
                  .breakglass(keyCtl.text.trim(), totpCtl.text.trim())
              : await MrcBroker.instance.login(
                  userCtl.text.trim(), passCtl.text, totpCtl.text.trim());
          if (!ctx.mounted) return;
          if (err == null) {
            Navigator.of(ctx).pop(true);
          } else {
            setState(() {
              busy = false;
              error = err;
            });
          }
        }

        return AlertDialog(
          title: const MendocinoHeader(),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  useBreakglass
                      ? 'Break-glass access. Every use is recorded in the audit log.'
                      : 'Sign in to start a remote session.',
                  style: TextStyle(
                    fontSize: 12,
                    color: useBreakglass ? Colors.orange.shade800 : null,
                  ),
                ),
                const SizedBox(height: 12),
                if (!useBreakglass) ...[
                  TextField(
                    controller: userCtl,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                  TextField(
                    controller: passCtl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => busy ? null : submit(),
                  ),
                ] else
                  TextField(
                    controller: keyCtl,
                    autofocus: true,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Break-glass key'),
                  ),
                TextField(
                  controller: totpCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Authenticator code',
                    hintText: 'leave blank if not enrolled',
                  ),
                  onSubmitted: (_) => busy ? null : submit(),
                ),
                const SizedBox(height: 10),
                if (error != null)
                  Text(error!,
                      style: TextStyle(color: Colors.red.shade400, fontSize: 12)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                              useBreakglass = !useBreakglass;
                              error = null;
                            }),
                    child: Text(
                      useBreakglass
                          ? 'Use a normal account'
                          : 'Use a break-glass key',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const MendocinoDeveloperCredit(),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in'),
            ),
          ],
        );
      },
    ),
  );

  return ok == true;
}

/// The gate: called by connect() before a session is opened.
///
/// Returns true if the connection may proceed. An unmanaged build (no broker configured)
/// always proceeds; a configured broker that refuses, or cannot be reached, does not.
Future<bool> mrcAuthorizeConnect(
    BuildContext context, String peerId, String kind) async {
  final broker = MrcBroker.instance;
  if (!broker.enabled) return true;

  if (!broker.isSignedIn) {
    if (!await mrcShowSignIn(context)) return false;
  }

  var (ticket, error) = await broker.requestSession(peerId, kind);

  // A token can expire between sign-in and use; offer one retry rather than failing.
  if (ticket == null && !broker.isSignedIn) {
    if (!context.mounted) return false;
    if (!await mrcShowSignIn(context)) return false;
    (ticket, error) = await broker.requestSession(peerId, kind);
  }

  if (ticket != null) return true;

  if (context.mounted && error != null) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connection refused'),
        content: Text(error!),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
  return false;
}
