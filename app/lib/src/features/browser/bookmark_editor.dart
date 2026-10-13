import 'dart:convert';

import 'package:flutter/material.dart';

import 'browser_bookmark_store.dart';
import 'profile_avatar_upload.dart';

class BookmarkEditor extends StatefulWidget {
  const BookmarkEditor(
      {super.key,
      required this.bookmark,
      required this.bookmarks,
      this.reservedUrl,
      this.pickImage});
  final BrowserBookmark bookmark;
  final List<BrowserBookmark> bookmarks;
  final String? reservedUrl;
  final Future<String?> Function()? pickImage;

  @override
  State<BookmarkEditor> createState() => _BookmarkEditorState();
}

class _BookmarkEditorState extends State<BookmarkEditor> {
  late final _title = TextEditingController(text: widget.bookmark.title);
  late final _url = TextEditingController(text: widget.bookmark.url);
  late String? _image = widget.bookmark.customImage;
  String? _error;
  bool _picking = false;

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final image = widget.pickImage != null
          ? await widget.pickImage!()
          : await pickBookmarkImage();
      if (mounted && image != null) setState(() => _image = image);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is AvatarUploadException
            ? e.message
            : 'Could not read the image.');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit saved app'),
        content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  TextField(
                      controller: _title,
                      decoration: const InputDecoration(labelText: 'App name'),
                      autofocus: true),
                  const SizedBox(height: 12),
                  TextField(
                      controller: _url,
                      decoration: const InputDecoration(
                          labelText: 'Launch URL',
                          helperText: 'The exact address opened by this tile.'),
                      keyboardType: TextInputType.url,
                      minLines: 1,
                      maxLines: 5,
                      autocorrect: false),
                  const SizedBox(height: 16),
                  if (_image != null)
                    Image.memory(base64Decode(_image!.substring(22)),
                        width: 72,
                        height: 72,
                        errorBuilder: (_, __, ___) => const Icon(Icons.apps)),
                  Wrap(spacing: 8, children: [
                    TextButton(
                        onPressed: _picking ? null : _pick,
                        child:
                            Text(_picking ? 'Choosing…' : 'Choose thumbnail')),
                    if (_image != null)
                      TextButton(
                          onPressed: _picking
                              ? null
                              : () => setState(() => _image = null),
                          child: const Text('Use automatic icon')),
                  ]),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _picking
                  ? null
                  : () {
                      final error = bookmarkEditError(widget.bookmarks,
                          widget.bookmark, _title.text, _url.text,
                          reservedUrl: widget.reservedUrl);
                      if (error != null) {
                        setState(() => _error = error);
                        return;
                      }
                      final url = canonicalBrowserBookmarkUrl(_url.text)!;
                      Navigator.pop(
                          context,
                          BrowserBookmark(
                              title: _title.text.trim(),
                              url: url,
                              customImage: _image,
                              startup: widget.bookmark.startup,
                              iconUrl: url == widget.bookmark.url
                                  ? widget.bookmark.iconUrl
                                  : null));
                    },
              child: const Text('Save')),
        ],
      );
}

Future<String?> pickBookmarkImage({bool background = false}) async {
  // Reuse the bounded local image decoder only; no avatar upload or signing.
  final bytes =
      await ProfileAvatarUpload().pick(maxDimension: background ? 1920 : 512);
  return bytes == null ? null : 'data:image/png;base64,${base64Encode(bytes)}';
}
