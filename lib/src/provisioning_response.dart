import 'dart:typed_data';

import 'package:esp_smartconfig/src/provisioning_request.dart';

/// Provisioning response
class ProvisioningResponse {
  /// Connected device BSSID
  final Uint8List deviceBssid;

  /// Friendly representation of [deviceBssid] in format aa:bb:cc:dd:ee:ff
  late final String deviceBssidString;

  ProvisioningResponse(this.deviceBssid) {
    if (deviceBssid.length != ProvisioningRequest.bssidLength) {
      throw ArgumentError("Invalid BSSID");
    }

    deviceBssidString =
        deviceBssid.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  /// Equality checking by [deviceBssid]
  bool operator ==(Object result) {
    if (result is ProvisioningResponse) {
      return bssidsAreEqual(result.deviceBssid, deviceBssid);
    }

    return false;
  }

  static bool bssidsAreEqual(Uint8List bssid1, Uint8List bssid2) {
    if (bssid1.length != 6 || bssid2.length != 6) {
      throw ArgumentError("Invalid BSSID");
    }

    for (int i = 0; i < 6; i++) {
      if (bssid1[i] != bssid2[i]) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode => super.hashCode;

  @override
  String toString() => "$deviceBssid";
}