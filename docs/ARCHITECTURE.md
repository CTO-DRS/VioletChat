# ARCHITECTURE — DRS NEXORA

## الطبقات

```
┌─────────────────────────────────────────────┐
│ features/  (شاشات + ودجات)                  │  UI فقط
├─────────────────────────────────────────────┤
│ state/     (Controllers — ChangeNotifier)   │  حالة + تنسيق
├─────────────────────────────────────────────┤
│ services/  (منطق الأعمال والبروتوكولات)      │
│  sync_engine  • realtime  • sessions        │
│  message_crypto  • media  • calls • presence│
├─────────────────────────────────────────────┤
│ data/      (models + repositories)          │  الوصول للخادم
├─────────────────────────────────────────────┤
│ crypto/    (Dart خالص — قابل للاختبار بلا UI)│  X3DH/Ratchet/GroupKeys
├─────────────────────────────────────────────┤
│ core/      (config, sqlite, logging, errors)│  بنية تحتية
└─────────────────────────────────────────────┘
```

قواعد الاعتماد: features → state → services → data/crypto → core.
لا يستورد crypto أي شيء من Flutter (يُختبر في CI بلا جهاز).

## تدفق رسالة صادرة

```
المستخدم يكتب
  → ChatController.sendText
  → SyncEngine.enqueueText        (حفظ محلي state=queued + صف outbox مشفر محلياً)
  → SyncEngine.drain (عند الاتصال)
      → MessageCryptoService.encryptInner
          ثنائية: SessionManager.encryptDirect (جلسة Ratchet لكل جهاز نظير)
          مجموعة: GroupKeys.messageKey(currentVersion)
  → MessageRepository.insertMessage (client_msg_id فريد = إرسال مضمّن التكرار)
  → تحديث الكاش state=sent وحذف صف الـ outbox
```

## تدفق رسالة واردة

```
Realtime (postgres_changes, RLS-scoped)
  → RealtimeService → SyncEngine.onRealtimeRow
      → decryptRow → MessageCache.upsert
  → ChatController يقرأ الكاش ويعرض
  → markDelivered/markRead (RPC)
أو (بعد انقطاع): إعادة اشتراك → sync.syncAll (جلب بالكيرسور) → دمج
```

## القرارات المعمارية الرئيسية

| القرار | السبب |
|---|---|
| Provider بلا codegen | أقل مخاطر بناء، كود واضح، قابل للاختبار |
| sqflite + JSON أعمدة cache | مخطط كاش مرن مع فهرسة على أعمدة البحث |
| client_msg_id UUID + فهرس فريد | إرسال idempotent — لا تكرار عند إعادة المحاولة |
| مغلف لكل جهاز (DM) | تعدد أجهزة حقيقي: كل جهاز يستلم جزءه الخاص |
| مفاتيح مجموعات بإصدارات | تدوير عند تغيير العضوية يمنع المغادرين من المستقبل |
| cursor pagination بلا limit(500) | كفاءة مع 100k+ رسالة |
| حضور heartbeat من الخادم | «متصل الآن» حقيقة مفروضة من الخادم — لا واجهة تدّعي ما لا تعرفه |
| Feature flags في AppConfig | لا أزرار وهمية: ما لم يُنفَّذ لا يظهر |

## تعدد الأجهزة
- كل جهاز له هوية كاملة (IK + SPK + OPKs) مسجلة في `devices`.
- المرسل يشفّر لكل أجهزة المستلم النشطة ويدرج مدخلاً مغلفاً لكل جهاز.
- جهاز مسجل بعد إرسال رسالة لا يستطيع فك القديمة (تصميم مقصود — بدون
  نسخ احتياطي سحابي للمفاتيح حفاظاً على الأمان).
- التحقق المستمر: مقارنة المفتاح العام المحلي مع المسجل عند كل دخول.

## الأداء
- ListView + pagination تدريجي، معاينات من ذاكرة sqflite.
- تكامل الحسابات الثقيلة (X25519/HKDF) مرة لكل رسالة في جلسة جاهزة.
- ذاكرة وسائط: RAM LRU + ملفات مؤقتة مشفرة، مقبض واحد لكل Realtime channel.
