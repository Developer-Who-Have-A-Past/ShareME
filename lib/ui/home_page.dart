import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../app_state.dart';
import '../services/discovery.dart';

class HomePage extends StatelessWidget {
  final AppState state;
  const HomePage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _Body(state: state),
    );
  }
}

class _Body extends StatelessWidget {
  final AppState state;
  const _Body({required this.state});

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _pinFor(BuildContext context, Peer peer) async {
    final cached = state.pins[peer.id];
    if (cached != null) return cached;
    final c = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PIN for ${peer.name}'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: InputDecoration(
            hintText: '6 digits shown on ${peer.name}',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
    if (pin == null || pin.length != 6) return null;
    state.setPin(peer.id, pin); // remembered, so no retyping next time
    return pin;
  }

  Future<void> _sendFiles(BuildContext context, Peer peer) async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = res?.paths.whereType<String>().toList() ?? [];
    if (paths.isEmpty || !context.mounted) return;
    await _sendPathsTo(context, peer, paths);
  }

  Future<void> _sendFolder(BuildContext context, Peer peer) async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !context.mounted) return;
    await _sendPathsTo(context, peer, [dir]);
  }

  Future<void> _sendPathsTo(
      BuildContext context, Peer peer, List<String> paths) async {
    final pin = await _pinFor(context, peer);
    if (pin == null) return;
    state.transfer.sendPaths(peer, pin, paths);
  }

  Future<void> _onDrop(BuildContext context, List<String> paths) async {
    if (paths.isEmpty) return;
    final peers = state.peers.values.toList();
    if (peers.isEmpty) {
      _snack(context, 'No nearby device to send to yet.');
      return;
    }
    Peer? target = peers.length == 1 ? peers.first : null;
    target ??= await showDialog<Peer>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Send ${paths.length} item(s) to…'),
        children: [
          for (final peer in peers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, peer),
              child: Text(peer.name),
            ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    await _sendPathsTo(context, target, paths);
  }

  Future<void> _sendText(BuildContext context, Peer peer) async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send text to ${peer.name}'),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'Type or paste text / link'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Send')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !context.mounted) return;
    final pin = await _pinFor(context, peer);
    if (pin == null) return;
    state.transfer.sendText(peer, pin, text);
  }

  Future<void> _sendClipboard(BuildContext context, Peer peer) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!context.mounted) return;
    if (text.isEmpty) {
      _snack(context, 'Clipboard is empty');
      return;
    }
    final pin = await _pinFor(context, peer);
    if (pin == null) return;
    state.transfer.sendText(peer, pin, text);
  }

  Future<void> _changeSaveDir(BuildContext context) async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where received files are saved',
    );
    if (dir == null) return;
    final err = await state.setSaveDir(dir);
    if (!context.mounted) return;
    _snack(context, err ?? 'Received files will be saved to $dir');
  }

  Future<void> _addByIp(BuildContext context) async {
    final c = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add device by IP'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
              hintText: 'e.g. 192.168.1.23',
              helperText: 'Shown as "Your IP" on the other device',
            ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (ip != null && ip.isNotEmpty) state.addManualPeer(ip);
  }

  void _openSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => ListenableBuilder(
        listenable: state,
        builder: (_, __) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Settings', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text('Theme'),
                const SizedBox(height: 6),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {state.themeMode},
                  onSelectionChanged: (s) => state.setTheme(s.first),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Copy received text to clipboard automatically'),
                  value: state.autoCopyText,
                  onChanged: state.setAutoCopy,
                ),
                if (Platform.isAndroid)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.download_for_offline_outlined),
                    title: const Text('Save received files to Downloads'),
                    subtitle: const Text('Needs "all files access" permission'),
                    onTap: () async {
                      final err = await state.useAndroidDownloads();
                      if (!context.mounted) return;
                      _snack(context, err ?? 'Saving to ${state.saveDir.path}');
                    },
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text('Trusted devices (${state.trusted.length})'),
                  subtitle: const Text('Auto-accepted without asking'),
                  trailing: TextButton(
                    onPressed: state.trusted.isEmpty ? null : state.clearTrusted,
                    child: const Text('Clear'),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.key_outlined),
                  title: Text('Remembered PINs (${state.pins.length})'),
                  subtitle: const Text('Saved so you don\'t retype them'),
                  trailing: TextButton(
                    onPressed: state.pins.isEmpty ? null : state.clearPins,
                    child: const Text('Clear'),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text('Received history (${state.inbox.length})'),
                  trailing: TextButton(
                    onPressed: state.inbox.isEmpty ? null : state.clearHistory,
                    child: const Text('Clear'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peers = state.peers.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return Scaffold(
      appBar: AppBar(
        title: const Text('ShareLAN'),
        actions: [
          IconButton(
            tooltip: 'Add device by IP',
            icon: const Icon(Icons.add_link),
            onPressed: () => _addByIp(context),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: DropTarget(
        onDragDone: (detail) =>
            _onDrop(context, detail.files.map((f) => f.path).toList()),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── This device ──
            Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('This device',
                              style: Theme.of(context).textTheme.labelMedium),
                          Text(state.name,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text('Your PIN (give it to the sender)',
                              style: Theme.of(context).textTheme.labelMedium),
                          Text(
                            state.pin,
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(
                                  letterSpacing: 6,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 4),
                          if (state.localIps.isNotEmpty)
                            Text('Your IP: ${state.localIps.join(", ")}',
                                style: Theme.of(context).textTheme.bodySmall),
                          Text(
                              Platform.isIOS
                                  ? 'Saves to: Files app > On My iPhone > ShareLAN'
                                  : 'Saves to: ${state.saveDir.path}',
                              style: Theme.of(context).textTheme.bodySmall),
                          if (!Platform.isIOS)
                          Wrap(
                            spacing: 4,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: const Text('Change folder'),
                                onPressed: () => _changeSaveDir(context),
                              ),
                              if (state.saveDir.path !=
                                  state.defaultSaveDir.path)
                                TextButton(
                                  onPressed: state.resetSaveDir,
                                  child: const Text('Reset'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'New PIN',
                      icon: const Icon(Icons.refresh),
                      onPressed: state.regeneratePin,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Nearby devices ──
            Text('Nearby devices',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (peers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Searching… Open ShareLAN on your other device and connect '
                  'both to the same WiFi. If nothing appears, add it by IP '
                  '(top right).',
                ),
              ),
            for (final peer in peers)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(peer.os == 'android'
                            ? Icons.smartphone
                            : peer.os == 'ios'
                                ? Icons.phone_iphone
                                : Icons.laptop),
                        title: Text(peer.name),
                        subtitle: Text('${peer.ip}:${peer.port}'),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.insert_drive_file_outlined),
                            label: const Text('Files'),
                            onPressed: () => _sendFiles(context, peer),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.folder_outlined),
                            label: const Text('Folder'),
                            onPressed: () => _sendFolder(context, peer),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.text_snippet_outlined),
                            label: const Text('Text'),
                            onPressed: () => _sendText(context, peer),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.content_paste),
                            label: const Text('Clipboard'),
                            onPressed: () => _sendClipboard(context, peer),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (peers.isNotEmpty &&
                (Platform.isWindows || Platform.isMacOS || Platform.isLinux))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Tip: drag files or folders onto this window to send them.',
                    style: TextStyle(fontSize: 12)),
              ),

            // ── Transfers ──
            if (state.transfers.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Transfers', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final t in state.transfers.take(20))
                Card(
                  child: ListTile(
                    leading: Icon(
                      t.failed
                          ? Icons.error_outline
                          : t.done
                              ? Icons.check_circle_outline
                              : t.incoming
                                  ? Icons.download
                                  : Icons.upload,
                      color: t.failed ? scheme.error : null,
                    ),
                    title: Text(t.label, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (t.active)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: LinearProgressIndicator(value: t.progress),
                          ),
                        Text(t.status),
                      ],
                    ),
                    trailing: t.active
                        ? IconButton(
                            tooltip: 'Cancel',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              t.cancelRequested = true;
                              t.status = 'Cancelling…';
                              state.touch(force: true);
                            },
                          )
                        : (t.failed && t.retry != null)
                            ? TextButton(
                                onPressed: () {
                                  final r = t.retry!;
                                  t.retry = null;
                                  state.touch(force: true);
                                  r();
                                },
                                child: const Text('Retry'),
                              )
                            : null,
                  ),
                ),
            ],

            // ── Received ──
            if (state.inbox.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Received', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final i in state.inbox.take(30))
                Card(
                  child: ListTile(
                    leading: Icon(i.text != null
                        ? Icons.text_snippet_outlined
                        : Icons.insert_drive_file_outlined),
                    title: Text(
                      i.text ?? i.path!.split(Platform.pathSeparator).last,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('from ${i.from}'),
                    trailing: i.text != null
                        ? IconButton(
                            tooltip: 'Copy',
                            icon: const Icon(Icons.copy),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: i.text!));
                              _snack(context, 'Copied');
                            },
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (Platform.isWindows)
                                IconButton(
                                  tooltip: 'Show in folder',
                                  icon: const Icon(Icons.folder_open),
                                  onPressed: () => Process.run(
                                      'explorer.exe', ['/select,${i.path!}']),
                                ),
                              IconButton(
                                tooltip: 'Open',
                                icon: const Icon(Icons.open_in_new),
                                onPressed: () async {
                                  final r = await OpenFilex.open(i.path!);
                                  if (r.type != ResultType.done &&
                                      context.mounted) {
                                    _snack(context, 'Could not open: ${r.message}');
                                  }
                                },
                              ),
                            ],
                          ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
