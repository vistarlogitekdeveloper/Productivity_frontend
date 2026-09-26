import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_trolley_photo.dart';
import 'supervisor_error_helper.dart';

/// Bottom-sheet camera modal that captures the trolley photo required
/// by the backend before a supervisor can STOP a running plan item.
/// Mirrors [SelfieModal] but uses the rear camera and uploads via
/// [DplApiService.uploadTrolleyPhoto].
///
/// Returns the persisted [DplTrolleyPhoto] on success (the caller
/// passes its `id` to `stopItem`). Returns `null` on cancel.
class TrolleyPhotoModal extends ConsumerStatefulWidget {
  final int planId;
  final int itemId;
  /// Pre-filled remarks (the supervisor already typed them in the
  /// Stop dialog). Stored alongside the photo on the audit row so
  /// reviewers see "why" without joining another table.
  final String? remarks;

  const TrolleyPhotoModal({
    super.key,
    required this.planId,
    required this.itemId,
    this.remarks,
  });

  @override
  ConsumerState<TrolleyPhotoModal> createState() => _TrolleyPhotoModalState();
}

class _TrolleyPhotoModalState extends ConsumerState<TrolleyPhotoModal> {
  final _picker = ImagePicker();
  Uint8List? _bytes;
  String _filename = 'trolley.jpg';
  bool _isCapturing = false;
  bool _isUploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tryRecoverLostShot();
  }

  /// Android can kill the Flutter activity while the system camera
  /// intent is in front, dropping the in-flight pickImage result.
  /// Recover it on rebuild so the supervisor doesn't lose the shot.
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
      _filename = picked.name.isEmpty ? 'trolley.jpg' : picked.name;
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
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 80,
        maxWidth: 1600,
      );
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
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() {
      _isUploading = true;
      _error = null;
    });
    final res = await ref.read(dplApiServiceProvider).uploadTrolleyPhoto(
          planId: widget.planId,
          itemId: widget.itemId,
          bytes: bytes,
          filename: _filename,
          remarks: widget.remarks,
        );
    if (!mounted) return;
    if (res.isError) {
      // Surface server-specific copy in-place rather than closing the
      // sheet — the supervisor can usually fix it by retaking.
      setState(() {
        _isUploading = false;
        _error = _mapUploadError(res.code, res.error);
      });
      return;
    }
    Navigator.of(context).pop(res.data);
  }

  String _mapUploadError(String? code, String? raw) {
    switch (code) {
      case 'INVALID_FILE':
        return 'Photo could not be processed. Please retake (JPEG/PNG, ≤ 5 MB).';
      case 'CONFLICT':
        return 'This item is no longer running, so a trolley photo isn\'t needed.';
      case 'FORBIDDEN':
        return 'You are not allowed to upload a photo for this plan.';
      default:
        return raw ?? 'Upload failed. Please retake and try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasShot = _bytes != null;
    final busy = _isCapturing || _isUploading;
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.92;
    final previewHeight =
        (media.size.height * 0.32).clamp(180.0, 280.0).toDouble();

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
                  Icon(
                    Icons.local_shipping_outlined,
                    color: VistarPalette.warn,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Trolley photo',
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
                    onPressed:
                        busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
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
                          border:
                              Border.all(color: VistarPalette.warnLine),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: VistarPalette.warn,
                              size: 18,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Capture a clear photo of the completed trolley. '
                                'This will be saved to the audit log and must be '
                                'taken before the item can be stopped.',
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
                          border:
                              Border.all(color: VistarPalette.line),
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: hasShot
                            ? Image.memory(_bytes!, fit: BoxFit.cover)
                            : Center(
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.local_shipping_outlined,
                                      size: 56,
                                      color: VistarPalette.txt2,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _isCapturing
                                          ? 'Opening camera…'
                                          : 'Tap below to capture the trolley',
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
                            border: Border.all(
                              color: VistarPalette.badLine,
                            ),
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        icon: const Icon(
                          Icons.camera_alt_outlined,
                          size: 18,
                        ),
                        label: Text(
                          hasShot ? 'Retake' : 'Capture Photo',
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
                                Icons.check_circle_outline,
                                size: 18,
                              ),
                        label: Text(
                          _isUploading
                              ? 'Uploading…'
                              : 'Submit Photo & Continue',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed:
                            (!hasShot || busy) ? null : _submit,
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

/// Convenience opener used by the plan-execution STOP flow. Returns
/// the persisted `DplTrolleyPhoto` on success, `null` if the
/// supervisor cancelled.
Future<DplTrolleyPhoto?> showTrolleyPhotoModal({
  required BuildContext context,
  required int planId,
  required int itemId,
  String? remarks,
}) {
  return showModalBottomSheet<DplTrolleyPhoto>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => TrolleyPhotoModal(
      planId: planId,
      itemId: itemId,
      remarks: remarks,
    ),
  );
}

/// Helper kept here so STOP-time error handlers can share the same
/// user-facing copy whether the failure happened during upload or
/// when calling `stopItem`.
String mapTrolleyStopError(String? code, String? raw) {
  switch (code) {
    case 'TROLLEY_PHOTO_REQUIRED':
      return 'A trolley photo is required to stop this item.';
    case 'TROLLEY_PHOTO_EXPIRED':
      return 'Your trolley photo expired before we could stop. Please retake.';
    case 'TROLLEY_PHOTO_MISMATCH':
      return 'That trolley photo belongs to a different item. Please retake.';
    default:
      return raw ?? 'Could not stop the item. Please try again.';
  }
}

/// Top-level snack-driver used by callers that prefer to surface the
/// error inline.
void surfaceTrolleyError(BuildContext context, String? code, String? raw) {
  DplSnack.error(context, mapTrolleyStopError(code, raw));
}

/// Convenience that delegates to the existing supervisor helper so
/// callers can keep their `handleSupervisorError` call sites
/// unchanged for non-trolley codes.
bool handleStopWithTrolleyError(
  BuildContext context,
  dynamic response, {
  String fallback = 'Failed to stop item.',
}) {
  final code = response.code?.toString() ?? '';
  if (code == 'TROLLEY_PHOTO_REQUIRED' ||
      code == 'TROLLEY_PHOTO_EXPIRED' ||
      code == 'TROLLEY_PHOTO_MISMATCH') {
    DplSnack.error(
      context,
      mapTrolleyStopError(code, response.error?.toString()),
    );
    return true;
  }
  return handleSupervisorError(context, response, fallback: fallback);
}
