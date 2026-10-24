/// v0.1.12 — واجهات «الموقع وجهات الاتصال»:
///   • ورقة اختيار مصدر الموقع (GPS حالي / نقطة على الخريطة)
///   • منتقي الخريطة التفاعلي (flutter_map + OSM — بلا مفاتيح API)
///   • منتقي بطاقة جهة اتصال (من الأصدقاء الحاليين)
///   • فقاعة الموقع (معاينة خريطة ثابتة + فتح خارجي)
///   • فقاعة البطاقة (أفاتار + اسم + @مستخدم + فتح المحادثة)
///
/// كل الإحداثيات والأسماء تُرسل داخل التشفير حصراً (InnerPayload)؛
/// بلاطات OSM تُجلب مجهولة لعرض المعاينة فقط.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../data/models/models.dart';
import '../../state/chats_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

// =====================================================================
// GPS helper
// =====================================================================

/// أخطاء تحديد الموقع برسائل عربية جاهزة للعرض.
class GpsException implements Exception {
  final String message;
  const GpsException(this.message);
}

class _Gps {
  /// الموقع الحالي — يتحقق من الخدمة ثم الأذونات ثم يقرأ النقطة.
  static Future<Position> fetch() async {
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      throw const GpsException(
          'خدمة الموقع معطلة — فعّلها من إعدادات الجهاز');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      throw const GpsException('أذونات الموقع مرفوضة');
    }
    if (perm == LocationPermission.deniedForever) {
      throw const GpsException(
          'أذونات الموقع مرفوضة نهائياً — فعّلها من إعدادات التطبيق');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 14),
      ),
    );
  }

  /// آخر موقع معروف بلا أذونات/خدمة إلزامية — لتهيئة الخريطة بهدوء.
  static Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }
}

/// نقطة تهيئة الخريطة من آخر موقع معروف — قد تُرجع null (لا إشارة
/// ولا أذونات). تُستخدم لمسار «على الخريطة» لتوسيط هادئ بلا مطالبة.
Future<LatLng?> lastKnownMapCenter() async {
  final p = await _Gps.lastKnown();
  return p == null ? null : LatLng(p.latitude, p.longitude);
}

// =====================================================================
// 1) ورقة اختيار المصدر
// =====================================================================

/// «الموقع الحالي» أو «على الخريطة» — null ألغى المستخدم.
Future<String?> showLocationSourceSheet(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('مشاركة الموقع',
                  textAlign: TextAlign.center,
                  style: Theme.of(sheetCtx).textTheme.titleMedium),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _sourceTile(
                      sheetCtx,
                      icon: Icons.my_location_rounded,
                      label: 'الموقع الحالي',
                      hint: 'عبر GPS',
                      gradient: const LinearGradient(
                          colors: [Color(0xFF059669), Color(0xFF34D399)]),
                      value: 'gps',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _sourceTile(
                      sheetCtx,
                      icon: Icons.map_rounded,
                      label: 'على الخريطة',
                      hint: 'اختر نقطة',
                      gradient: const LinearGradient(
                          colors: [Color(0xFF0EA5E9), Color(0xFF22D3EE)]),
                      value: 'map',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'تُشفَّر الإحداثيات طرف-لطرف قبل الإرسال — الخادم لا يراها.\n'
                'بلاطات المعاينة تُجلب مجهولة من OpenStreetMap.',
                textAlign: TextAlign.center,
                style: Theme.of(sheetCtx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );

Widget _sourceTile(
  BuildContext sheetCtx, {
  required IconData icon,
  required String label,
  required String hint,
  required Gradient gradient,
  required String value,
}) {
  return InkWell(
    onTap: () => Navigator.of(sheetCtx).pop(value),
    borderRadius: BorderRadius.circular(18),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(sheetCtx)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: AppTheme.darkBorder.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(14),
              boxShadow: AppTheme.glow(alpha: 0.35, blur: 14),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w800)),
          const SizedBox(height: 1),
          Text(hint, style: Theme.of(sheetCtx).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

// =====================================================================
// 2) منتقي الخريطة (ورقة كاملة الارتفاع تقريباً)
// =====================================================================

/// الافتراضي عند غياب أي إشارة (وسط الرياض) — يعاد توسيطه فوراً إن
/// توفر GPS/آخر موقع معروف.
const LatLng kDefaultMapCenter = LatLng(24.7136, 46.6753);

/// منتقي نقطة على خريطة حية — دبوس ثابت في وسط الشاشة، المستخدم
/// يحرك الخريطة تحته، ويكتب وسماً اختيارياً ثم «مشاركة هذا الموقع».
class LocationPickSheet extends StatefulWidget {
  final LatLng initialCenter;

  /// true = جرّب GPS فور الفتح (زر «الموقع الحالي») ووسطّط الخريطة
  /// على النتيجة؛ أخطاء GPS تعرض تنبيهاً ولا تغلق الورقة.
  final bool locateFirst;
  final double initialAccuracy;

  const LocationPickSheet({
    super.key,
    required this.initialCenter,
    this.locateFirst = false,
    this.initialAccuracy = 0,
  });

  @override
  State<LocationPickSheet> createState() => _LocationPickSheetState();
}

class _LocationPickSheetState extends State<LocationPickSheet> {
  final MapController _map = MapController();
  final _labelCtrl = TextEditingController();
  late LatLng _center = widget.initialCenter;
  late double _zoom = widget.locateFirst ? 15 : 16;
  bool _locating = false;
  double _accuracy = widget.initialAccuracy;

  @override
  void initState() {
    super.initState();
    if (widget.locateFirst) _locateNow();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _locateNow() async {
    setState(() => _locating = true);
    try {
      final p = await _Gps.fetch();
      if (!mounted) return;
      setState(() {
        _center = LatLng(p.latitude, p.longitude);
        _accuracy = p.accuracy;
        _zoom = 16;
      });
      try {
        _map.move(_center, _zoom);
      } catch (_) {
        // الخريطة لم تُركّب بعد — onPositionChanged سيقرأ المركز الجديد.
      }
    } on GpsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('تعذر تحديد موقعك — حرّك الخريطة يدوياً')));
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _zoomBy(int d) {
    final nz = ((_zoom + d).clamp(2.0, 19.0)).toDouble();
    try {
      _map.move(_center, nz);
    } catch (_) {}
  }

  void _share() {
    final label = _labelCtrl.text.trim();
    Navigator.of(context).pop(LocationInfo(
      lat: _center.latitude,
      lng: _center.longitude,
      label: label.isEmpty ? null : label,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      height: MediaQuery.of(context).size.height * 0.84,
      decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('مشاركة الموقع',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FlutterMap(
                        mapController: _map,
                        options: MapOptions(
                          initialCenter: _center,
                          initialZoom: _zoom,
                          minZoom: 2,
                          maxZoom: 19,
                          onPositionChanged: (pos, hasGesture) {
                            final c = pos.center;
                            if (c == null) return;
                            _center = c;
                            final z = pos.zoom;
                            if (z != null) _zoom = z;
                          },
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.drs.nexora',
                            maxNativeZoom: 19,
                          ),
                        ],
                      ),
                      // دبوس الوسط — ثابت، الخريطة تتحرك تحته.
                      const Center(
                        child: _CenterPin(),
                      ),
                      // أزرار التكبير/التصغير + إعادة GPS.
                      Positioned.directional(
                        textDirection: Directionality.of(context),
                        end: 10,
                        bottom: 10,
                        child: Column(
                          children: [
                            _mapButton(Icons.add_rounded, () => _zoomBy(1)),
                            const SizedBox(height: 8),
                            _mapButton(
                                Icons.remove_rounded, () => _zoomBy(-1)),
                            const SizedBox(height: 8),
                            _mapButton(Icons.my_location_rounded,
                                () => unawaitedLocate()),
                          ],
                        ),
                      ),
                      if (_locating)
                        const Positioned(
                          top: 10,
                          start: 10,
                          end: 10,
                          child: IgnorePointer(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: _LocatingChip(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _labelCtrl,
                maxLength: 40,
                decoration: InputDecoration(
                  hintText: 'وسم الموقع (اختياري) — مثل: المنزل',
                  counterText: '',
                  prefixIcon: const Icon(Icons.label_outline, size: 20),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 8),
              if (_accuracy > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'دقة GPS: ±${_accuracy.round()} متر',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandPrimary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('مشاركة هذا الموقع',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                onPressed: _share,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// زر GPS داخل الورقة — يستدعي _locateNow بأمان من الإغلاق.
  void unawaitedLocate() => _locateNow();

  Widget _mapButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: AppTheme.brandSecondary),
        ),
      ),
    );
  }
}

class _LocatingChip extends StatelessWidget {
  const _LocatingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, spreadRadius: 1)
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('جاري تحديد موقعك...', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// دبوس الوسط — نقطة بنفسجية بحلقة بيضاء وظل، تبرز فوق أي بلاطة.
class _CenterPin extends StatelessWidget {
  const _CenterPin();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: AppTheme.brandPrimary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: AppTheme.glow(
                color: AppTheme.brandPrimary, alpha: 0.5, blur: 12),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -6),
          child: Container(
            width: 2,
            height: 12,
            color: AppTheme.brandPrimary.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// 3) منتقي بطاقة جهة اتصال
// =====================================================================

/// قائمة الأصدقاء (نظراء المحادثات المباشرة) — اختيار أحدهم يُرجع
/// بطاقة مشفرة تُرسل إلى المحادثة الحالية.
Future<ContactInfo?> showContactPickSheet(BuildContext context) =>
    showModalBottomSheet<ContactInfo>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        final chats = sheetCtx.read<ChatsController>().chats;
        // نظراء المحادثات المباشرة فقط — بلا تكرار، مرتبين بالاسم.
        final seen = <String>{};
        final peers = <Profile>[];
        for (final c in chats) {
          final p = c.peer;
          if (c.isGroup || p == null) continue;
          if (seen.add(p.id)) peers.add(p);
        }
        peers.sort((a, b) => a.displayName.compareTo(b.displayName));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('مشاركة جهة اتصال',
                    textAlign: TextAlign.center,
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                    'البطاقة تُرسل مشفرة — لمستَها يفتح المحادثة مباشرة',
                    textAlign: TextAlign.center,
                    style: Theme.of(sheetCtx).textTheme.bodySmall),
                const SizedBox(height: 8),
                if (peers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 26),
                    child: Column(
                      children: [
                        Icon(Icons.person_off_rounded,
                            size: 40,
                            color: Theme.of(sheetCtx)
                                .colorScheme
                                .onSurfaceVariant),
                        const SizedBox(height: 10),
                        const Text('لا يوجد أصدقاء بعد',
                            style: TextStyle(fontSize: 14)),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: peers.length,
                      itemBuilder: (_, i) {
                        final p = peers[i];
                        return ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          leading: AvatarWidget(profile: p, radius: 20),
                          title: Text(p.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('@${p.username}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.of(sheetCtx).pop(ContactInfo(
                              username: p.username,
                              displayName: p.displayName)),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

// =====================================================================
// 4) فقاعة الموقع
// =====================================================================

/// معاينة خريطة ثابتة (بلا تفاعل — IgnorePointer) + وسم/إحداثيات +
/// أثر حقوق OSM الصغير. اللمس يفتح الخريطة الخارجية عبر [onOpen]،
/// والضغط المطول يفتح قائمة الرسالة عبر [onSheet].
class LocationBubble extends StatelessWidget {
  final Message msg;
  final bool mine;
  final VoidCallback? onOpen;
  final VoidCallback? onSheet;

  const LocationBubble({
    super.key,
    required this.msg,
    required this.mine,
    this.onOpen,
    this.onSheet,
  });

  @override
  Widget build(BuildContext context) {
    final loc = msg.location;
    final surface = mine
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.05);
    if (loc == null) {
      // حمولة تالفة — نص دفاعي بدل فقاعة فارغة.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: surface, borderRadius: BorderRadius.circular(14)),
        child: Text('📍 موقع',
            style: TextStyle(
                fontSize: 14,
                color: mine
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface)),
      );
    }
    final dim = mine
        ? Colors.white70
        : Theme.of(context).textTheme.bodySmall?.color;
    return InkWell(
      onTap: onOpen,
      onLongPress: onSheet,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 240,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 132,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // معاينة ساكنة — لا تفاعل ولا تكبير داخل الفقاعة.
                  IgnorePointer(
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: LatLng(loc.lat, loc.lng),
                        initialZoom: 15,
                        minZoom: 2,
                        maxZoom: 19,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.drs.nexora',
                          maxNativeZoom: 19,
                        ),
                      ],
                    ),
                  ),
                  const Center(child: _CenterPin()),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (loc.label != null && loc.label!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          Icon(Icons.place_rounded,
                              size: 14,
                              color: mine
                                  ? Colors.white
                                  : AppTheme.brandSecondary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              loc.label!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: mine
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Text(
                    loc.coordsText(),
                    style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: dim),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text('© OpenStreetMap',
                        style: TextStyle(fontSize: 8.5, color: dim)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// 5) فقاعة بطاقة جهة الاتصال
// =====================================================================

/// بطاقة مشفرة: أفاتار + اسم + @مستخدم — اللمس يحل الاسم عبر مسار
/// البحث القائم (نفس مسار QR) ويفتح المحادثة المباشرة.
class ContactBubble extends StatelessWidget {
  final Message msg;
  final bool mine;
  final VoidCallback? onOpen;
  final VoidCallback? onSheet;

  const ContactBubble({
    super.key,
    required this.msg,
    required this.mine,
    this.onOpen,
    this.onSheet,
  });

  @override
  Widget build(BuildContext context) {
    final card = msg.contact;
    final surface = mine
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.05);
    if (card == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: surface, borderRadius: BorderRadius.circular(14)),
        child: Text('👤 بطاقة جهة اتصال',
            style: TextStyle(
                fontSize: 14,
                color: mine
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface)),
      );
    }
    final dim = mine
        ? Colors.white70
        : Theme.of(context).textTheme.bodySmall?.color;
    final fg = mine
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onOpen,
      onLongPress: onSheet,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 262),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AvatarWidget(
              label: card.displayName,
              seedId: card.username,
              radius: 21,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(card.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: fg)),
                  Text('@${card.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: dim)),
                  const SizedBox(height: 2),
                  Text('مستخدم Violet Chat — لمستَ لفتح المحادثة',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontStyle: FontStyle.italic,
                          color: dim)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_left_rounded,
                size: 22,
                color: mine ? Colors.white70 : AppTheme.brandSecondary),
          ],
        ),
      ),
    );
  }
}

/// فحص سريع: بطاقة تالفة (اسم مستخدم فارغ) تُفسد الحمولة دفاعياً.
bool isValidContactPayload(Map<String, dynamic>? j) =>
    ContactInfo.fromJson(j) != null;

/// ثابت جاهز للاستخدام في المعاينات خارج هذا الملف.
const String kLocationPreview = '📍 موقع';
const String kContactPreview = '👤 بطاقة جهة اتصال';
const String kPollPreview = '📊 استطلاع رأي';

/// يجمع معاينة الرد/القائمة لكل الأنواع الخاصة — مصدر واحد للحقيقة
/// (فقاعة الرد، شريط الرد، معاينة قائمة المحادثات، لافتة التثبيت).
String kindPreview(Message m) {
  final t = (m.text ?? '').trim();
  switch (m.kind) {
    case AppConstants.kindLocation:
      return kLocationPreview;
    case AppConstants.kindContact:
      return '👤 ${m.contact?.displayName ?? 'بطاقة جهة اتصال'}';
    case AppConstants.kindPoll:
      return kPollPreview;
    case AppConstants.kindStoryReply:
      return t.isEmpty ? 'رد على حالة' : '↩ $t';
    case AppConstants.kindMedia:
      // التسمية التوضيحية تتفوق على نوع الوسيط (سلوك الرسائل المعتاد).
      if (t.isNotEmpty) return t;
      return switch (m.media?.type) {
        AppConstants.mediaImage => '📷 صورة',
        AppConstants.mediaAudio => '🎤 رسالة صوتية',
        AppConstants.mediaVideo => '🎬 فيديو',
        _ => '📎 ملف',
      };
    default:
      return t.isEmpty ? 'رسالة' : t;
  }
}
