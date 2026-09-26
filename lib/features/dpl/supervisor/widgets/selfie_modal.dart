import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../manager/widgets/error_retry.dart';
import '../providers/dpl_identity_provider.dart';

/// Camera modal that the IdentityGate opens when a fresh selfie is
/// required. Captures via the front camera on native, falls back to
/// the browser's `getUserMedia` on web (handled by image_picker).
///
/// Returns `true` from `Navigator.pop` on a successful upload.
class SelfieModal extends ConsumerStatefulWidget {
  /// One of `DplIdentityContext.*` values.
  final String context;
  final int? planId;
  final int? planItemId;

  const SelfieModal({
    super.key,
    required this.context,
    this.planId,
    this.planItemId,
  });

  @override
  ConsumerState<SelfieModal> createState() => _SelfieModalState();
}

class _SelfieModalState extends ConsumerState<SelfieModal> {
  final _picker = ImagePicker();
  Uint8List? _bytes;
  String _filename = 'selfie.jpg';
  bool _isCapturing = false;
  bool _isUploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Android can kill the Flutter activity while the system camera
    // intent is in front, which drops the result of the in-flight
    // pickImage call. Recover it on rebuild so the user doesn't have
    // to retake the photo.
    _tryRecoverLostShot();
  }

  Future<void> _tryRecoverLostShot() async {
    try {
      final lost = await _picker.retrieveLostData();
      if (lost.isEmpty || lost.file == null) return;
      if (lost.type != RetrieveType.image) return;
      await _useXFile(lost.file!);
    } catch (_) {
      // Platform doesn't support retrieveLostData — safe to ignore.
    }
  }

  Future<void> _useXFile(XFile picked) async {
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _filename = picked.name.isEmpty ? 'selfie.jpg' : picked.name;
      _isCapturing = false;
      _error = null;
    });
  }

  Future<void> _capture() async {
    setState(() {
      _isCapturing = true;
      _error = null;
    });
    try {
      XFile? picked = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 80,
        maxWidth: 1280,
      );

      // pickImage returns null when Android killed our process during
      // the camera intent. Pull the result back via retrieveLostData.
      if (picked == null) {
        try {
          final lost = await _picker.retrieveLostData();
          if (!lost.isEmpty &&
              lost.file != null &&
              lost.type == RetrieveType.image) {
            picked = lost.file;
          }
        } catch (_) {
          // ignore — handled below
        }
      }

      if (picked == null) {
        if (!mounted) return;
        setState(() => _isCapturing = false);
        return;
      }

      await _useXFile(picked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCapturing = false;
        _error = 'Could not open camera: $e';
      });
    }
  }

  Future<void> _submit() async {
    if (_bytes == null) return;
    setState(() {
      _isUploading = true;
      _error = null;
    });
    final res = await ref.read(dplApiServiceProvider).verifyIdentity(
          bytes: _bytes!,
          filename: _filename,
          context: widget.context,
          planId: widget.planId,
          planItemId: widget.planItemId,
        );
    if (!mounted) return;
    if (res.isError) {
      setState(() {
        _isUploading = false;
        _error = res.error ?? 'Upload failed.';
      });
      return;
    }
    ref.invalidate(dplIdentityStatusProvider);
    if (!mounted) return;
    DplSnack.success(context, 'Identity verified.');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final hasShot = _bytes != null;
    final busy = _isCapturing || _isUploading;
    final media = MediaQuery.of(context);

    // Cap the sheet at 92% of viewport — leaves room for the system
    // gesture / dismiss handle and avoids the keyboard-overlap overflow
    // we were hitting before.
    final maxHeight = media.size.height * 0.92;

    // Compact the preview on short / portrait screens so the buttons
    // are always reachable above the fold.
    final previewHeight =
        (media.size.height * 0.30).clamp(180.0, 260.0).toDouble();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 16 + media.viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Drag affordance + header ----
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: VistarPalette.line2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.shield_outlined,
                      color: VistarPalette.warn),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Identity verification',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    visualDensity: VisualDensity.compact,
                    onPressed: busy
                        ? null
                        : () => Navigator.of(context).pop(false),
                  ),
                ],
              ),

              // ---- Scrollable body ----
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: VistarPalette.warnBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: VistarPalette.warnLine),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: VistarPalette.warn, size: 18),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'This photo will be verified later. Any misuse '
                                'will be flagged and may lead to disciplinary '
                                'action.',
                                style: TextStyle(
                                  color: VistarPalette.warnInk,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: previewHeight,
                        decoration: BoxDecoration(
                          color: VistarPalette.surface3,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: VistarPalette.line),
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: hasShot
                            ? Image.memory(_bytes!, fit: BoxFit.cover)
                            : Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.person_outline,
                                      size: 56,
                                      color: VistarPalette.txt2,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _isCapturing
                                          ? 'Opening camera…'
                                          : 'Tap below to take a selfie',
                                      style: TextStyle(
                                        color: VistarPalette.txt2,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: VistarPalette.badBg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: VistarPalette.badLine),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: VistarPalette.badInk,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ---- Sticky action buttons ----
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.camera_alt_outlined, size: 18),
                        label: Text(
                          hasShot ? 'Retake' : 'Take Selfie',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: busy ? null : _capture,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        icon: _isUploading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.verified_user_outlined,
                                size: 18,
                              ),
                        label: Text(
                          _isUploading ? 'Uploading…' : 'Submit & Continue',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: (!hasShot || busy) ? null : _submit,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
