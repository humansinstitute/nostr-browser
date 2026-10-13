import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ProfileKeyExportDialog extends StatefulWidget {
  const ProfileKeyExportDialog({required this.unlock, super.key});
  final Future<String> Function(String pin) unlock;
  @override
  State<ProfileKeyExportDialog> createState() => _ProfileKeyExportDialogState();
}

class _ProfileKeyExportDialogState extends State<ProfileKeyExportDialog>
    with WidgetsBindingObserver {
  final _pin = TextEditingController();
  String? _nsec;
  String? _error;
  bool _busy = false;
  bool _accepted = false;
  int _generation = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pin.dispose();
    _nsec = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _generation++;
      _timer?.cancel();
      _pin.clear();
      if (mounted) {
        setState(() {
          _nsec = null;
          _accepted = false;
        });
      }
    }
  }

  Future<void> _reveal() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final secret = await widget.unlock(_pin.text);
      if (!mounted || generation != _generation) return;
      _pin.clear();
      setState(() => _nsec = secret);
      _timer = Timer(const Duration(seconds: 60), () {
        if (mounted) {
          setState(() {
            _nsec = null;
            _accepted = false;
          });
        }
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() =>
            _error = 'Unable to export. Check your PIN and active identity.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Export private key'),
        content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Anyone with your nsec can control your Nostr identity. Never share it or paste it into a website. Store a backup in a trusted password manager. Clipboard contents may be accessible to other apps or synced to other devices.'),
                const SizedBox(height: 16),
                if (_nsec == null) ...[
                  CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _accepted,
                      onChanged: _busy
                          ? null
                          : (value) =>
                              setState(() => _accepted = value ?? false),
                      title: const Text(
                          'I understand the risk of exposing my private key.')),
                  TextField(
                      controller: _pin,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(12)
                      ],
                      decoration:
                          const InputDecoration(labelText: 'Confirm your PIN')),
                ] else ...[
                  const Text(
                      'Private key (nsec) — hidden again after 60 seconds'),
                  SelectableText(_nsec!, key: const ValueKey('exported-nsec')),
                  TextButton.icon(
                      onPressed: () async {
                        final secret = _nsec;
                        if (secret == null) return;
                        await Clipboard.setData(ClipboardData(text: secret));
                        if (mounted) {
                          setState(() => _error =
                              'Copied. Clear your clipboard after saving your backup.');
                        }
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy nsec')),
                ],
                if (_error != null) Text(_error!),
              ],
            ))),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close')),
          if (_nsec == null)
            FilledButton(
                onPressed: !_accepted || _busy ? null : _reveal,
                child: Text(_busy ? 'Verifying…' : 'Reveal nsec')),
        ],
      );
}
