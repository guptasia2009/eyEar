import 'dart:typed_data';

import 'package:image_picker/image_picker.dart' as picker;

/// Thrown when the user backs out of the camera without taking a photo.
class ImageCaptureCancelled implements Exception {}

/// A source of JPEG images for the Cortex pipeline.
///
/// The rest of the pipeline depends only on this interface, so swapping
/// the phone camera back out for the ESP32's BLE camera is a one-line
/// change wherever the source is constructed.
abstract class ImageSource {
  Future<Uint8List> captureJpeg();
}

/// Captures a photo using the phone's own camera via the system camera UI.
class PhoneCameraSource implements ImageSource {
  final picker.ImagePicker _picker = picker.ImagePicker();

  @override
  Future<Uint8List> captureJpeg() async {
    final shot = await _picker.pickImage(
      source: picker.ImageSource.camera,
      maxWidth: 1280,
      imageQuality: 85,
    );
    if (shot == null) throw ImageCaptureCancelled();
    return shot.readAsBytes();
  }
}

/// Placeholder for receiving a JPEG from the EyEar device over BLE.
///
/// The current firmware never sends image bytes over BLE - it only sends
/// finished description text - so there is nothing to wire this to yet.
/// When the firmware gains a JPEG-over-BLE transfer, implement it here;
/// nothing else in the pipeline needs to change.
class BleCameraSource implements ImageSource {
  @override
  Future<Uint8List> captureJpeg() async {
    throw UnsupportedError(
      'BLE image capture is not implemented: the EyEar firmware does not '
      'send image bytes over BLE yet. Use PhoneCameraSource on this branch.',
    );
  }
}
