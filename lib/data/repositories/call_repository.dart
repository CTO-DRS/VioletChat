import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';

/// Call history persistence (calls table, RLS: chat members only).
class CallRepository {
  final SupabaseClient client;
  CallRepository(this.client);

  Future<String> createCall({
    required String chatId,
    required String calleeId,
    required String type,
  }) async {
    final res = await client
        .from('calls')
        .insert({
          'chat_id': chatId,
          'caller_id': client.auth.currentUser!.id,
          'callee_id': calleeId,
          'type': type,
          'status': 'ringing',
        })
        .select('id')
        .single();
    return res['id'] as String;
  }

  Future<void> updateStatus(String callId, String status,
          {int durationSec = 0}) =>
      client.from('calls').update({
        'status': status,
        if (status == 'ended' || status == 'declined' || status == 'missed')
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        'duration_sec': durationSec,
      }).eq('id', callId);

  Future<List<CallRecord>> myCalls({int limit = 100}) async {
    final rows = await client
        .from('calls')
        .select()
        .or('caller_id.eq.${client.auth.currentUser!.id},callee_id.eq.${client.auth.currentUser!.id}')
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => CallRecord.fromJson(r as Map<String, dynamic>))
        .toList();
  }
}
