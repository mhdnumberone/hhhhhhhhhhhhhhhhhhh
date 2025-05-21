// lib/config/app_config.dart

// !! هام: في بيئة حقيقية، استخدم متغيرات البيئة أو تقنيات إدارة الأسرار
// لا تضع عناوين IP أو نطاقات حقيقية هنا مباشرة في التحكم بالمصادر (Version Control)
// هذا مجرد مثال توضيحي.

// --- HTTP Server Configuration ---
// هذا العنوان يشير إلى النطاق الذي وفرته Cloudflare Tunnel
// والذي يوجه مباشرة إلى Flask HTTP server على جهازك
const String C2_HTTP_SERVER_URL =
    'https://ws.sosa-qav.es'; // <-- تم استبداله بعنوان Cloudflare Tunnel HTTPS

// --- WebSocket (Socket.IO) Server Configuration ---
// طالما أن نفس النطاق يدعم ترقية WebSocket (Cloudflare يدعمها)،
// نغير البروتوكول فقط إلى wss:// (للاتصال المشفر)
const String C2_SOCKET_IO_URL =
    'wss://ws.sosa-qav.es'; // <-- استخدم wss مع Cloudflare لأنه HTTPS

const Duration C2_SOCKET_IO_RECONNECT_DELAY = Duration(seconds: 5);
const int C2_SOCKET_IO_RECONNECT_ATTEMPTS = 5;
const Duration C2_HEARTBEAT_INTERVAL = Duration(
  seconds: 45,
); // Interval for client to send heartbeat
