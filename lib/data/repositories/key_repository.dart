import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../crypto/identity.dart';
import '../../crypto/x3dh.dart';

/// Key server access — device registration, prekey bundles,
/// one-time prekey claiming.
class KeyRepository {
  final SupabaseClient client;
  KeyRepository(this.client);

  String get myId => client.auth.currentUser!.id;

  /// Register (or refresh) this device + publish its prekey bundle.
  Future<void> registerDevice(
      DeviceIdentity identity, String deviceName, String platform) async {
    final bundle = await IdentityManager.publicBundle(identity);
    await client.rpc('register_device', params: {
      'p_device_id': identity.deviceId,
      'p_device_name': deviceName,
      'p_platform': platform,
      'p_bundle': bundle,
    });
  }

  /// Top up one-time prekeys when we run low.
  Future<void> topUpOneTimePrekeys(DeviceIdentity identity) async {
    final bundle = await IdentityManager.publicBundle(identity);
    await client.rpc('topup_one_time_prekeys', params: {
      'p_device_id': identity.deviceId,
      'p_one_time_prekeys': bundle['one_time_prekeys'],
    });
  }

  /// Fetch prekey bundles for ALL devices of a user and claim one
  /// OPK per device (atomic on the server).
  Future<List<PrekeyBundle>> fetchBundles(String userId) async {
    final res = await client
        .rpc('get_prekey_bundles', params: {'p_user_id': userId}) as List;
    return res
        .map((e) => PrekeyBundle.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Compare the locally stored public identity with the server copy
  /// for THIS device. Returns true when they match.
  Future<bool> verifyLocalIdentityMatchesServer(DeviceIdentity identity) async {
    final row = await client
        .from('devices')
        .select('identity_key, signing_key')
        .eq('user_id', myId)
        .eq('device_id', identity.deviceId)
        .maybeSingle();
    if (row == null) return false;
    final bundle = await IdentityManager.publicBundle(identity);
    return row['identity_key'] == bundle['identity_key'] &&
        row['signing_key'] == bundle['signing_key'];
  }
}

/// JSON helper for bundles sent over RPC.
String encodeBundle(Map<String, dynamic> bundle) => jsonEncode(bundle);
