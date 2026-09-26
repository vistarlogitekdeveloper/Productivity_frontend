import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';

/// Pulls the numeric photo id out of the backend's
/// `stop_trolley_photo_url`, which the manager/supervisor plans
/// endpoints embed on every stopped item. Returns `null` if the URL
/// shape changed and we can't be confident which id to load.
int? trolleyPhotoIdFromUrl(String? url) {
  if (url == null) return null;
  final text = url.trim();
  if (text.isEmpty) return null;
  // Backend ships paths like:
  //   /api/v1/dpl/supervisor/trolley-photos/5/image
  //   /api/v1/dpl/manager/trolley-photos/5/image
  final match = RegExp(r'trolley-photos/(\d+)/image').firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Small tappable thumbnail (default 64×64) that loads the trolley
/// photo bytes once via the DPL API and opens a full-screen,
/// pinch-zoomable viewer on tap. Use it next to completed plan-item
/// rows so a manager can verify the trolley without leaving the
/// plan detail screen.
class TrolleyPhotoThumbnail extends ConsumerStatefulWidget {
  /// `stop_trolley_photo_url` from the plan-item payload. The widget
  /// extracts the photo id and fetches the bytes itself.
  final String? photoUrl;
  final double size;
  final String heroTag;

  const TrolleyPhotoThumbnail({
    super.key,
    required this.photoUrl,
    required this.heroTag,
    this.size = 64,
  });

  @override
  ConsumerState<TrolleyPhotoThumbnail> createState() =>
      _TrolleyPhotoThumbnailState();
}

class _TrolleyPhotoThumbnailState extends ConsumerState<TrolleyPhotoThumbnail> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = false;
  int? _photoId;

  @override
  void initState() {
    super.initState();
    _photoId = trolleyPhotoIdFromUrl(widget.photoUrl);
    if (_photoId != null) _load();
  }

  @override
  void didUpdateWidget(covariant TrolleyPhotoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newId = trolleyPhotoIdFromUrl(widget.photoUrl);
    if (newId != _photoId) {
      _photoId = newId;
      _bytes = null;
      _error = null;
      if (newId != null) _load();
    }
  }

  Future<void> _load() async {
    final id = _photoId;
    if (id == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // Managers and supervisors can both read via the supervisor
    // image endpoint — the backend's auth layer accepts the
    // manager role too. Keeping a single read path means we don't
    // care which role the current user has.
    final res =
        await ref.read(dplApiServiceProvider).getSupervisorTrolleyPhotoBytes(id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.isError || res.data == null) {
        _error = res.error ?? 'Failed to load photo.';
      } else {
        _bytes = res.data;
      }
    });
  }

  Future<void> _openFullScreen() async {
    final bytes = _bytes;
    if (bytes == null) {
      if (_photoId != null && !_loading) _load();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _TrolleyPhotoViewer(
          bytes: bytes,
          heroTag: widget.heroTag,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_photoId == null) return const SizedBox.shrink();
    final size = widget.size;
    return Tooltip(
      message: 'View trolley photo',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openFullScreen,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: VistarPalette.surface3,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: VistarPalette.line),
            ),
            clipBehavior: Clip.hardEdge,
            child: _buildContent(size),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(double size) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: IconButton(
          icon: Icon(
            Icons.refresh,
            size: 18,
            color: VistarPalette.bad,
          ),
          tooltip: 'Reload',
          onPressed: _load,
        ),
      );
    }
    final bytes = _bytes;
    if (bytes != null) {
      return Hero(
        tag: widget.heroTag,
        child: Image.memory(bytes, fit: BoxFit.cover),
      );
    }
    return Center(
      child: Icon(
        Icons.local_shipping_outlined,
        size: 22,
        color: VistarPalette.txt2,
      ),
    );
  }
}

class _TrolleyPhotoViewer extends StatelessWidget {
  final Uint8List bytes;
  final String heroTag;

  const _TrolleyPhotoViewer({required this.bytes, required this.heroTag});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Trolley photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: Hero(
          tag: heroTag,
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
