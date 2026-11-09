import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    if (kIsWeb) databaseFactory = databaseFactoryFfiWeb;
    await DBHelper.instance.database;

    final session = await DBHelper.instance.getActiveSession();
    Widget initialScreen = const SplashScreen();

    if (session != null) {
      final name = session['fullName']?.toString() ?? '';
      final mail = session['email']?.toString() ?? '';
      final isDrv = session['isDriver'] == 1;

      final user = await DBHelper.instance.getUserByEmail(mail);
      final phone = user?['mobile']?.toString() ?? '';
      final gender = user?['gender']?.toString() ?? 'Not specified';
      final photo = user?['profilePhoto']?.toString() ?? '';
      final licensePhoto = user?['licensePhoto']?.toString() ?? '';

      userProfile.updateProfile(name, mail, driver: isDrv, phone: phone, g: gender, photo: photo, licensePhoto: licensePhoto);
      initialScreen = SplashScreen(
        targetScreen: isDrv ? const DriverDashboard() : const CommuterDashboard(),
      );
    }

    runApp(ESakayTodaApp(initialScreen: initialScreen));
  } catch (e, st) {
    debugPrint('Startup failed: $e\n$st');
    runApp(StartupErrorApp(error: e.toString()));
  }
}

class StartupErrorApp extends StatelessWidget {
  final String error;
  const StartupErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('eSakay TODA could not start',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  SelectableText(error),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppColors {
  static const yellow = Color(0xFFFCDC73);
  static const coral = Color(0xFFE76268);
  static const navy = Color(0xFF193948);
  static const teal = Color(0xFF4FADC0);
  static const cream = Color(0xFFFDF3D6);
  static const field = Color(0xFFF3F5F7);
  static const sky = Color(0xFFD9EEF3);
}

class ThemeManager extends ChangeNotifier {
  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  void toggleTheme(bool value) {
    _isDarkMode = value;
    notifyListeners();
  }
}

final ThemeManager themeManager = ThemeManager();

TextStyle heading(double size, {Color? color}) => GoogleFonts.paytoneOne(
      fontSize: size,
      color: color ?? (themeManager.isDarkMode ? Colors.white : AppColors.navy),
    );

const String kTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

List<double> _saturationMatrix(double s) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final inv = 1 - s;
  return [
    inv * r + s, inv * g, inv * b, 0, 0,
    inv * r, inv * g + s, inv * b, 0, 0,
    inv * r, inv * g, inv * b + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

Widget mapTiles() => ColorFiltered(
      colorFilter: ColorFilter.matrix(_saturationMatrix(0.35)),
      child: TileLayer(
        urlTemplate: kTileUrl,
        userAgentPackageName: 'com.esakay.toda',
      ),
    );

Widget mapAttribution() => const RichAttributionWidget(
      attributions: [
        TextSourceAttribution('OpenStreetMap contributors'),
      ],
    );

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class LocationUtils {
  static final Map<String, LatLng> streetCoords = {
    'Rhodora Street': const LatLng(14.2250, 120.9750),
    'Iris Street': const LatLng(14.2262, 120.9765),
    'Dante Ganancial Street': const LatLng(14.2238, 120.9735),
    'Begonia Street': const LatLng(14.2275, 120.9780),
    'Camia Street': const LatLng(14.2220, 120.9720),
    'Dahlia Street': const LatLng(14.2285, 120.9795),
  };

  static LatLng getCoords(String street) {
    return streetCoords[street] ?? const LatLng(14.2250, 120.9750);
  }

  static String calculateDistanceInfo(LatLng p1, LatLng p2) {
    const Distance distance = Distance();
    final double meter = distance.as(LengthUnit.Meter, p1, p2);
    final int minutes = max(1, (meter / 150).round());
    if (meter < 1000) {
      return '${meter.round()} m away ($minutes min)';
    }
    final double km = meter / 1000;
    return '${km.toStringAsFixed(1)} km away ($minutes min)';
  }
}

class PlaceResult {
  final String name;
  final String address;
  final LatLng point;
  final bool isPreset;

  const PlaceResult({
    required this.name,
    required this.address,
    required this.point,
    this.isPreset = false,
  });
}

class GeocodingService {
  static const String _host = 'nominatim.openstreetmap.org';
  static Map<String, String> get _headers =>
      kIsWeb ? const {} : const {'User-Agent': 'eSakayTODA/1.0 (com.esakay.toda)'};

  static Future<List<PlaceResult>> search(String query) async {
    final uri = Uri.https(_host, '/search', {
      'q': query,
      'format': 'jsonv2',
      'limit': '6',
      'addressdetails': '1',
      'accept-language': 'en',
      'countrycodes': 'ph',
      'viewbox': '120.85,14.35,121.10,14.10',
    });
    final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw Exception('Geocoding failed');
    final List<dynamic> data = jsonDecode(res.body) as List<dynamic>;
    return data.map((raw) {
      final m = raw as Map<String, dynamic>;
      return PlaceResult(
        name: _shortName(m),
        address: m['display_name']?.toString() ?? '',
        point: LatLng(double.parse(m['lat'].toString()), double.parse(m['lon'].toString())),
      );
    }).toList();
  }

  static Future<PlaceResult> reverse(LatLng point) async {
    final uri = Uri.https(_host, '/reverse', {
      'lat': point.latitude.toString(),
      'lon': point.longitude.toString(),
      'format': 'jsonv2',
      'zoom': '18',
      'addressdetails': '1',
      'accept-language': 'en',
    });
    final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw Exception('Reverse geocoding failed');
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    if (m['error'] != null) throw Exception(m['error'].toString());
    return PlaceResult(
      name: _shortName(m),
      address: m['display_name']?.toString() ?? '',
      point: point,
    );
  }

  static String _shortName(Map<String, dynamic> m) {
    final name = (m['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final addr = m['address'];
    if (addr is Map) {
      final road = (addr['road'] ?? addr['neighbourhood'] ?? addr['suburb'] ?? '').toString().trim();
      if (road.isNotEmpty) return road;
    }
    final display = (m['display_name'] ?? '').toString();
    return display.isEmpty ? 'Dropped pin' : display.split(',').first.trim();
  }
}

class FareCalculator {
  static int calculateFare(PlaceResult from, PlaceResult to) {
    const Distance d = Distance();
    final roadMeters = d.as(LengthUnit.Meter, from.point, to.point) * 1.3;
    if (roadMeters <= 1000) return 40;
    final extraHalfKm = ((roadMeters - 1000) / 500).ceil();
    return 40 + extraHalfKm * 10;
  }
}

class DBHelper {
  static final DBHelper instance = DBHelper._init();
  static Database? _database;

  DBHelper._init();

  get database async {
    if (_database != null) return _database!;
    _database = await _initDB('esakay_database.db');
    return _database!;
  }

  _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 18,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 16) {
          await db.execute('ALTER TABLE orders ADD COLUMN pickupLat REAL');
          await db.execute('ALTER TABLE orders ADD COLUMN pickupLng REAL');
          await db.execute('ALTER TABLE orders ADD COLUMN dropLat REAL');
          await db.execute('ALTER TABLE orders ADD COLUMN dropLng REAL');
        }
        if (oldVersion < 17) {
          await db.execute('ALTER TABLE orders ADD COLUMN orderType TEXT DEFAULT "eSakay"');
          await db.execute('ALTER TABLE users ADD COLUMN mobile TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN gender TEXT');
        }
        if (oldVersion < 18) {
          await db.execute('ALTER TABLE users ADD COLUMN profilePhoto TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN licensePhoto TEXT');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fullName TEXT,
            email TEXT,
            password TEXT,
            mobile TEXT,
            gender TEXT,
            isDriver INTEGER,
            plate TEXT,
            toda TEXT,
            license TEXT,
            profilePhoto TEXT,
            licensePhoto TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pickup TEXT,
            dropoff TEXT,
            fare TEXT,
            status TEXT,
            driverName TEXT,
            orderType TEXT,
            pickupLat REAL,
            pickupLng REAL,
            dropLat REAL,
            dropLng REAL
          )
        ''');
        await db.execute('''
          CREATE TABLE session (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fullName TEXT,
            email TEXT,
            isDriver INTEGER
          )
        ''');
      },
    );
  }

  insertUser(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('users', row);
  }

  getUser(String email, String password) async {
    final db = await instance.database;
    final results = await db.query(
      'users',
      where: 'email = ? AND password = ?',
      whereArgs: [email, password],
    );
    if (results.isNotEmpty) return results.first;
    return null;
  }

  getUserByEmail(String email) async {
    final db = await instance.database;
    final results = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [email],
    );
    if (results.isNotEmpty) return results.first;
    return null;
  }

  updateUserProfile(String email, String fullName, String mobile, String gender, String profilePhoto, String licensePhoto) async {
    final db = await instance.database;
    await db.update(
      'users',
      {
        'fullName': fullName,
        'mobile': mobile,
        'gender': gender,
        'profilePhoto': profilePhoto,
        'licensePhoto': licensePhoto,
      },
      where: 'email = ?',
      whereArgs: [email],
    );
  }

  deleteUserAccount(String email) async {
    final db = await instance.database;
    await db.delete('users', where: 'email = ?', whereArgs: [email]);
    await clearSession();
  }

  saveSession(String fullName, String email, int isDriver) async {
    final db = await instance.database;
    await db.delete('session');
    await db.insert('session', {
      'fullName': fullName,
      'email': email,
      'isDriver': isDriver,
    });
  }

  getActiveSession() async {
    final db = await instance.database;
    final results = await db.query('session');
    if (results.isNotEmpty) return results.first;
    return null;
  }

  clearSession() async {
    final db = await instance.database;
    await db.delete('session');
  }

  insertOrder(String pickup, String dropoff, String fare, LatLng pickupPoint, LatLng dropPoint, {String type = 'eSakay'}) async {
    final db = await instance.database;
    return await db.insert('orders', {
      'pickup': pickup,
      'dropoff': dropoff,
      'fare': fare,
      'status': 'Pending',
      'driverName': '',
      'orderType': type,
      'pickupLat': pickupPoint.latitude,
      'pickupLng': pickupPoint.longitude,
      'dropLat': dropPoint.latitude,
      'dropLng': dropPoint.longitude,
    });
  }

  getOrders({String? filterType}) async {
    final db = await instance.database;
    if (filterType == null || filterType == 'All') {
      return await db.query('orders', orderBy: 'id DESC');
    }
    if (filterType == 'Cancelled') {
      return await db.query('orders', where: 'status = ?', whereArgs: ['Cancelled'], orderBy: 'id DESC');
    }
    return await db.query('orders', where: 'orderType = ?', whereArgs: [filterType], orderBy: 'id DESC');
  }

  getOrderById(int id) async {
    final db = await instance.database;
    final results = await db.query('orders', where: 'id = ?', whereArgs: [id]);
    if (results.isNotEmpty) return results.first;
    return null;
  }

  getPendingBookings() async {
    final db = await instance.database;
    return await db.query('orders', where: 'status = ?', whereArgs: ['Pending'], orderBy: 'id DESC');
  }

  getDriverAcceptedOrders(String driverName) async {
    final db = await instance.database;
    return await db.query(
      'orders',
      where: 'status IN (?, ?) AND driverName = ?',
      whereArgs: ['Ongoing', 'Completed', driverName],
      orderBy: 'id DESC',
    );
  }

  acceptOrder(int id, String driverName) async {
    final db = await instance.database;
    await db.update(
      'orders',
      {'status': 'Ongoing', 'driverName': driverName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  updateOrderStatus(int id, String status) async {
    final db = await instance.database;
    await db.update('orders', {'status': status}, where: 'id = ?', whereArgs: [id]);
  }
}

class UserProfileModel extends ChangeNotifier {
  String fullName = '';
  String email = '';
  String mobile = '';
  String gender = 'Not specified';
  bool isDriver = false;
  String profilePhoto = '';
  String licensePhoto = '';

  void updateProfile(String name, String mail, {bool driver = false, String phone = '', String g = 'Not specified', String photo = '', String licensePhoto = ''}) {
    fullName = name;
    email = mail;
    isDriver = driver;
    mobile = phone;
    gender = g;
    profilePhoto = photo;
    this.licensePhoto = licensePhoto;
    notifyListeners();
  }
}

final UserProfileModel userProfile = UserProfileModel();

class SplashLogo extends StatelessWidget {
  final double size;
  const SplashLogo({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.yellow,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: TricycleIllustration(width: size * 0.75),
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  final Widget? targetScreen;
  const SplashScreen({super.key, this.targetScreen});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _scaleAnim = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.navy,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ScaleTransition(
            scale: _scaleAnim,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SplashLogo(size: 140),
                const SizedBox(height: 24),
                Text('eSakay TODA', style: heading(28, color: AppColors.yellow)),
                const SizedBox(height: 8),
                const Text(
                  'Queueing and dispatch for neighborhood tricycles.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 40),
                SizedBox(
                  width: 220,
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.yellow,
                      foregroundColor: AppColors.navy,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => widget.targetScreen ?? const OnboardingScreen()),
                      );
                    },
                    child: Text('Start Now', style: heading(16, color: AppColors.navy)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TricycleIllustration extends StatelessWidget {
  final double width;
  const TricycleIllustration({super.key, this.width = 260});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width * 150 / 240,
      child: CustomPaint(painter: _TricyclePainter()),
    );
  }
}

class _TricyclePainter extends CustomPainter {
  void _wheel(Canvas c, Offset center, double r) {
    final p = Paint()..style = PaintingStyle.fill;
    p.color = AppColors.navy;
    c.drawCircle(center, r, p);
    p.color = AppColors.cream;
    c.drawCircle(center, r * 0.5, p);
    p.color = AppColors.navy;
    c.drawCircle(center, r * 0.15, p);
  }

  @override
  void paint(Canvas c, Size size) {
    c.save();
    c.scale(size.width / 240);
    final p = Paint()..style = PaintingStyle.fill;

    p.color = AppColors.navy.withValues(alpha: 0.12);
    c.drawOval(const Rect.fromLTWH(14, 128, 212, 14), p);

    p.color = AppColors.yellow;
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(18, 52, 104, 64), const Radius.circular(16)), p);

    p.color = AppColors.teal;
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(18, 100, 104, 8), const Radius.circular(4)), p);

    p.color = AppColors.navy;
    c.drawRRect(
      RRect.fromRectAndCorners(
        const Rect.fromLTWH(12, 36, 116, 18),
        topLeft: const Radius.circular(14),
        topRight: const Radius.circular(14),
        bottomLeft: const Radius.circular(3),
        bottomRight: const Radius.circular(3),
      ),
      p,
    );

    p.color = AppColors.sky;
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(30, 60, 60, 36), const Radius.circular(8)), p);

    p.color = AppColors.navy;
    c.drawCircle(const Offset(60, 74), 15, p);
    p.color = AppColors.coral;
    c.drawCircle(const Offset(60, 78), 13, p);
    p.color = Colors.white;
    c.drawCircle(const Offset(55, 76), 3.2, p);
    c.drawCircle(const Offset(65, 76), 3.2, p);
    p.color = AppColors.navy;
    c.drawCircle(const Offset(55.5, 76), 1.5, p);
    c.drawCircle(const Offset(65.5, 76), 1.5, p);
    final smile = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = AppColors.navy;
    c.drawArc(const Rect.fromLTWH(54, 79, 12, 8), 0.2, 2.7, false, smile);

    p.color = AppColors.yellow;
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(124, 76, 62, 34), const Radius.circular(12)), p);

    p.color = AppColors.navy;
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(128, 68, 36, 9), const Radius.circular(4)), p);

    final navyLine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = AppColors.navy;
    navyLine.strokeWidth = 5;
    c.drawLine(const Offset(180, 72), const Offset(198, 114), navyLine);
    navyLine.strokeWidth = 4;
    c.drawLine(const Offset(178, 68), const Offset(194, 54), navyLine);

    p.color = AppColors.coral;
    c.drawCircle(const Offset(193, 84), 7, p);
    p.color = Colors.white;
    c.drawCircle(const Offset(193, 84), 2.8, p);

    _wheel(c, const Offset(62, 116), 15);
    _wheel(c, const Offset(150, 116), 15);
    _wheel(c, const Offset(200, 116), 15);

    c.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color textColor;
  final IconData? icon;

  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = AppColors.navy,
    this.textColor = Colors.white,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: heading(16, color: textColor)),
                if (icon != null) ...[
                  const SizedBox(width: 8),
                  Icon(icon, color: textColor, size: 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboard;

  const AppField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.keyboard,
  });

  @override
  State<AppField> createState() => _AppFieldState();
}

class _AppFieldState extends State<AppField> {
  late bool _obscureText;

  @override
  void initState() {
    super.initState();
    _obscureText = widget.obscure;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: widget.controller,
        obscureText: _obscureText,
        keyboardType: widget.keyboard,
        style: const TextStyle(fontSize: 14, color: AppColors.navy),
        decoration: InputDecoration(
          filled: true,
          fillColor: AppColors.field,
          hintText: widget.hint,
          hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
          prefixIcon: Icon(widget.icon, size: 18, color: Colors.grey),
          suffixIcon: widget.obscure
              ? IconButton(
                  icon: Icon(
                    _obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                    color: Colors.grey,
                  ),
                  onPressed: () => setState(() => _obscureText = !_obscureText),
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg = Colors.white;
    switch (status) {
      case 'Pending':
        bg = AppColors.yellow;
        fg = AppColors.navy;
        break;
      case 'Ongoing':
        bg = AppColors.teal;
        break;
      case 'Completed':
        bg = AppColors.navy;
        break;
      case 'Cancelled':
        bg = AppColors.coral;
        break;
      default:
        bg = AppColors.coral;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

class DestPin extends StatelessWidget {
  const DestPin({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: AppColors.coral.withValues(alpha: 0.25), shape: BoxShape.circle),
      child: Center(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: AppColors.coral,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
          ),
        ),
      ),
    );
  }
}

class MyLocationDot extends StatelessWidget {
  const MyLocationDot({super.key});

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF2F80ED);
    return Container(
      decoration: BoxDecoration(color: blue.withValues(alpha: 0.2), shape: BoxShape.circle),
      child: Center(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      ),
    );
  }
}

class OriginDot extends StatelessWidget {
  const OriginDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: AppColors.teal,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
        ),
      ),
    );
  }
}

class DriverPin extends StatelessWidget {
  const DriverPin({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.teal,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
      ),
      child: const Icon(Icons.electric_rickshaw, color: Colors.white, size: 20),
    );
  }
}

class RouteMap extends StatelessWidget {
  final LatLng driver;
  final LatLng pickup;
  final double height;
  final bool showRoute;

  const RouteMap({
    super.key,
    required this.driver,
    required this.pickup,
    this.height = 180,
    this.showRoute = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: FlutterMap(
          options: MapOptions(
            initialCameraFit: CameraFit.coordinates(
              coordinates: [driver, pickup],
              padding: const EdgeInsets.all(48),
              maxZoom: 17,
            ),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
          ),
          children: [
            mapTiles(),
            if (showRoute)
              PolylineLayer(
                polylines: [Polyline(points: [driver, pickup], color: AppColors.teal, strokeWidth: 4)],
              ),
            MarkerLayer(
              markers: [
                Marker(point: driver, width: 40, height: 40, child: const DriverPin()),
                Marker(point: pickup, width: 44, height: 44, child: const DestPin()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ESakayTodaApp extends StatelessWidget {
  final Widget initialScreen;
  const ESakayTodaApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([userProfile, themeManager]),
      builder: (context, _) {
        return MaterialApp(
          title: 'eSakay TODA',
          debugShowCheckedModeBanner: false,
          themeMode: themeManager.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: AppColors.cream,
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppColors.yellow,
              primary: AppColors.navy,
              secondary: AppColors.teal,
              surface: AppColors.cream,
            ),
            snackBarTheme: SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.navy,
              contentTextStyle: const TextStyle(color: Colors.white),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF121212),
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppColors.yellow,
              brightness: Brightness.dark,
              primary: AppColors.yellow,
              secondary: AppColors.teal,
              surface: const Color(0xFF1E1E1E),
            ),
            snackBarTheme: SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.yellow,
              contentTextStyle: const TextStyle(color: AppColors.navy),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
          home: initialScreen,
        );
      },
    );
  }
}

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.yellow,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('eSakay TODA', style: heading(16, color: AppColors.navy)),
                  const Icon(Icons.sort_rounded, color: AppColors.navy),
                ],
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
              child: Container(
                width: double.infinity,
                color: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
                  child: Column(
                    children: [
                      const SplashLogo(size: 100),
                      const SizedBox(height: 20),
                      Text('Start a\nride now.', textAlign: TextAlign.center, style: heading(36)),
                      const SizedBox(height: 10),
                      Text(
                        'Queueing and dispatch for your neighborhood tricycles.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: themeManager.isDarkMode ? Colors.white70 : Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 32),
                      PillButton(
                        label: "I'm a Commuter",
                        icon: Icons.arrow_forward_rounded,
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AuthScreen(isDriver: false)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      PillButton(
                        label: "I'm a Driver",
                        color: AppColors.coral,
                        icon: Icons.arrow_forward_rounded,
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AuthScreen(isDriver: true)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  final bool isDriver;
  const AuthScreen({super.key, required this.isDriver});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = false;
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _todaCtrl = TextEditingController();
  final _licenseCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    _mobileCtrl.dispose();
    _plateCtrl.dispose();
    _todaCtrl.dispose();
    _licenseCtrl.dispose();
    super.dispose();
  }

  void _showVerificationDialog(VoidCallback onSuccess) {
    final codeCtrl = TextEditingController();
    final phoneText = _mobileCtrl.text.trim();
    final emailText = _emailCtrl.text.trim();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dContext) => AlertDialog(
        title: Text('Account Verification', style: heading(18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Enter the 4-digit code sent to your Gmail ($emailText) and Phone Number ($phoneText):'),
            const SizedBox(height: 16),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: InputDecoration(
                hintText: 'e.g. 1234',
                filled: true,
                fillColor: AppColors.field,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.navy),
            onPressed: () {
              if (codeCtrl.text.trim().length == 4) {
                Navigator.pop(dContext);
                onSuccess();
              } else {
                showSnack(context, 'Please enter a valid 4-digit code.');
              }
            },
            child: const Text('Verify & Proceed', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _proceed() async {
    final emailText = _emailCtrl.text.trim();
    if (!emailText.contains('@')) {
      showSnack(context, 'Please enter a valid Gmail address containing "@".');
      return;
    }

    if (_isLogin) {
      final user = await DBHelper.instance.getUser(emailText, _passCtrl.text);
      if (!mounted) return;
      if (user == null) {
        showSnack(context, widget.isDriver ? 'Driver account not found.' : 'Account not found. Please sign up.');
        return;
      }
      final registeredAsDriver = user['isDriver'] == 1;
      if (registeredAsDriver != widget.isDriver) {
        showSnack(context, registeredAsDriver
            ? 'This account is a driver account. Go back and choose Driver.'
            : 'This account is a commuter account. Go back and choose Commuter.');
        return;
      }
      final name = user['fullName']?.toString() ?? '';
      final mobile = user['mobile']?.toString() ?? '';
      final gender = user['gender']?.toString() ?? 'Not specified';
      final photo = user['profilePhoto']?.toString() ?? '';
      final licensePhoto = user['licensePhoto']?.toString() ?? '';

      userProfile.updateProfile(name, emailText, driver: widget.isDriver, phone: mobile, g: gender, photo: photo, licensePhoto: licensePhoto);
      await DBHelper.instance.saveSession(name, emailText, widget.isDriver ? 1 : 0);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => widget.isDriver ? const DriverDashboard() : const CommuterDashboard()),
        (route) => false,
      );
    } else {
      final missing = _nameCtrl.text.isEmpty ||
          _passCtrl.text.isEmpty ||
          _mobileCtrl.text.isEmpty ||
          (widget.isDriver && (_plateCtrl.text.isEmpty || _todaCtrl.text.isEmpty || _licenseCtrl.text.isEmpty));
      if (missing) {
        showSnack(context, widget.isDriver
            ? 'Please fill out all driver, mobile number, and vehicle details.'
            : 'Please fill out all required fields including your mobile number.');
        return;
      }

      _showVerificationDialog(() async {
        final name = _nameCtrl.text;
        final mobile = _mobileCtrl.text;
        await DBHelper.instance.insertUser({
          'fullName': name,
          'email': emailText,
          'password': _passCtrl.text,
          'mobile': mobile,
          'gender': 'Not specified',
          'isDriver': widget.isDriver ? 1 : 0,
          'plate': widget.isDriver ? _plateCtrl.text : '',
          'toda': widget.isDriver ? _todaCtrl.text : '',
          'license': widget.isDriver ? _licenseCtrl.text : '',
          'profilePhoto': '',
          'licensePhoto': '',
        });
        if (!mounted) return;
        userProfile.updateProfile(name, emailText, driver: widget.isDriver, phone: mobile);
        await DBHelper.instance.saveSession(name, emailText, widget.isDriver ? 1 : 0);
        if (!mounted) return;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => widget.isDriver ? const DriverDashboard() : const CommuterDashboard()),
          (route) => false,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.yellow,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 24, 10),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.navy),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Text(widget.isDriver ? 'eSakay Driver' : 'eSakay TODA', style: heading(16, color: AppColors.navy)),
                  const Spacer(),
                  const Icon(Icons.sort_rounded, color: AppColors.navy),
                ],
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
              child: Container(
                color: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(child: SplashLogo(size: _isLogin || !widget.isDriver ? 100 : 80)),
                            const SizedBox(height: 16),
                            Text(
                              _isLogin ? 'Welcome\nback.' : (widget.isDriver ? 'Join the\nqueue.' : 'Start a\nride now.'),
                              textAlign: TextAlign.center,
                              style: heading(32),
                            ),
                            const SizedBox(height: 24),
                            AppField(
                              controller: _emailCtrl,
                              hint: 'Gmail',
                              icon: Icons.mail_outline_rounded,
                              keyboard: TextInputType.emailAddress,
                            ),
                            AppField(
                              controller: _passCtrl,
                              hint: 'Password',
                              icon: Icons.lock_outline_rounded,
                              obscure: true,
                            ),
                            if (!_isLogin) ...[
                              AppField(controller: _nameCtrl, hint: 'Full name', icon: Icons.person_outline_rounded),
                              AppField(
                                controller: _mobileCtrl,
                                hint: 'Phone Number (e.g., 09955352737)',
                                icon: Icons.phone_iphone_rounded,
                                keyboard: TextInputType.phone,
                              ),
                              if (widget.isDriver) ...[
                                AppField(controller: _plateCtrl, hint: 'Plate number (e.g., ABC 1234)', icon: Icons.confirmation_number_outlined),
                                AppField(controller: _todaCtrl, hint: 'TODA number / Name', icon: Icons.groups_outlined),
                                AppField(controller: _licenseCtrl, hint: "Driver's license number", icon: Icons.badge_outlined),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: SizedBox(
                        height: 64,
                        child: Row(
                          children: [
                            Expanded(
                              child: Center(
                                child: TextButton(
                                  onPressed: () => setState(() => _isLogin = !_isLogin),
                                  child: Text(
                                    _isLogin ? 'Register' : 'Log in',
                                    style: TextStyle(
                                      color: themeManager.isDarkMode ? Colors.white : AppColors.navy,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Material(
                              color: AppColors.navy,
                              borderRadius: const BorderRadius.only(topLeft: Radius.circular(28)),
                              child: InkWell(
                                borderRadius: const BorderRadius.only(topLeft: Radius.circular(28)),
                                onTap: _proceed,
                                child: SizedBox(
                                  width: 170,
                                  height: 64,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(_isLogin ? 'Go' : 'Sign up', style: heading(16, color: Colors.white)),
                                      const SizedBox(width: 10),
                                      const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CommuterDashboard extends StatefulWidget {
  const CommuterDashboard({super.key});

  @override
  State<CommuterDashboard> createState() => _CommuterDashboardState();
}

class _CommuterDashboardState extends State<CommuterDashboard> {
  int _currentIndex = 0;
  String _selectedFilter = 'All';

  @override
  Widget build(BuildContext context) {
    final List<Widget> tabs = [
      CommuterHomeScreen(
        onFilterSelected: (filter) {
          setState(() {
            _selectedFilter = filter;
            _currentIndex = 1;
          });
        },
      ),
      OrdersScreen(initialFilter: _selectedFilter),
      const ConcernsScreen(),
      const AccountScreen(),
    ];

    return Scaffold(
      body: tabs[_currentIndex],
      bottomNavigationBar: NavigationBar(
        backgroundColor: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
        indicatorColor: AppColors.yellow,
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt_rounded), label: 'Orders'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble_rounded), label: 'Concerns'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person_rounded), label: 'Account'),
        ],
      ),
    );
  }
}

class CommuterHomeScreen extends StatefulWidget {
  final Function(String filter)? onFilterSelected;
  const CommuterHomeScreen({super.key, this.onFilterSelected});

  @override
  State<CommuterHomeScreen> createState() => _CommuterHomeScreenState();
}

class _CommuterHomeScreenState extends State<CommuterHomeScreen> {
  final MapController _map = MapController();
  final LatLng _defaultCenter = const LatLng(14.2250, 120.9750);

  final TextEditingController _pickupCtrl = TextEditingController();
  final TextEditingController _dropCtrl = TextEditingController();
  final FocusNode _pickupFocus = FocusNode();
  final FocusNode _dropFocus = FocusNode();

  PlaceResult? _pickup;
  PlaceResult? _dropoff;
  String? _pickupError;
  String? _dropError;
  int _pending = 0;
  Timer? _pickupTimer;
  Timer? _dropTimer;
  LatLng? _myLocation;

  bool get _hasRoute => _pickup != null && _dropoff != null;
  int get _fare => _hasRoute ? FareCalculator.calculateFare(_pickup!, _dropoff!) : 40;

  @override
  void dispose() {
    _pickupTimer?.cancel();
    _dropTimer?.cancel();
    _pickupCtrl.dispose();
    _dropCtrl.dispose();
    _pickupFocus.dispose();
    _dropFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateMe(overwrite: false));
  }

  Future<LatLng?> _getDevicePosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _locateMe({required bool overwrite}) async {
    setState(() => _pending++);
    final here = await _getDevicePosition();
    if (!mounted) return;
    if (here == null) {
      setState(() => _pending--);
      return;
    }
    setState(() => _myLocation = here);
    _map.move(here, 17);

    if (!overwrite && _pickupCtrl.text.trim().isNotEmpty) {
      setState(() => _pending--);
      return;
    }

    PlaceResult place;
    try {
      place = await GeocodingService.reverse(here);
    } catch (_) {
      place = PlaceResult(
        name: 'My location',
        address: '${here.latitude.toStringAsFixed(5)}, ${here.longitude.toStringAsFixed(5)}',
        point: here,
      );
    }
    if (!mounted) return;
    _pickupTimer?.cancel();
    _pickupCtrl.text = place.name;
    setState(() {
      _pending--;
      _setPlace(0, place);
    });
    _frameCamera(focus: place);
  }

  TextEditingController _ctrl(int side) => side == 0 ? _pickupCtrl : _dropCtrl;

  void _setPlace(int side, PlaceResult? place, {String? error}) {
    if (side == 0) {
      _pickup = place;
      _pickupError = error;
    } else {
      _dropoff = place;
      _dropError = error;
    }
  }

  void _onTextChanged(int side, String text) {
    (side == 0 ? _pickupTimer : _dropTimer)?.cancel();
    setState(() => _setPlace(side, null));
    if (text.trim().length < 3) return;
    final timer = Timer(const Duration(milliseconds: 900), () => _resolve(side));
    if (side == 0) {
      _pickupTimer = timer;
    } else {
      _dropTimer = timer;
    }
  }

  void _onSubmitted(int side) {
    (side == 0 ? _pickupTimer : _dropTimer)?.cancel();
    _resolve(side);
    if (side == 0) _dropFocus.requestFocus();
  }

  void _clearField(int side) {
    (side == 0 ? _pickupTimer : _dropTimer)?.cancel();
    _ctrl(side).clear();
    setState(() => _setPlace(side, null));
  }

  Future<void> _resolve(int side) async {
    final query = _ctrl(side).text.trim();
    if (query.length < 3) return;

    setState(() => _pending++);
    PlaceResult? found;
    String? error;
    try {
      final results = await GeocodingService.search(query);
      if (results.isNotEmpty) {
        found = results.first;
      } else {
        error = 'No match found.';
      }
    } catch (_) {
      error = 'Search unavailable.';
    }
    if (!mounted) return;
    setState(() => _pending--);
    if (_ctrl(side).text.trim() != query) return;

    if (found != null) {
      _applyPlace(side, found);
    } else {
      setState(() => _setPlace(side, null, error: error));
    }
  }

  void _applyPlace(int side, PlaceResult place) {
    setState(() => _setPlace(side, place));
    _frameCamera(focus: place);
  }

  void _frameCamera({PlaceResult? focus}) {
    if (_hasRoute) {
      final h = MediaQuery.of(context).size.height;
      _map.fitCamera(
        CameraFit.coordinates(
          coordinates: [_pickup!.point, _dropoff!.point],
          padding: EdgeInsets.fromLTRB(60, h * 0.38, 60, 120),
          maxZoom: 17,
        ),
      );
    } else if (focus != null) {
      _map.move(focus.point, 16.5);
    }
  }

  Future<void> _onMapLongPress(LatLng point) async {
    setState(() => _pending++);
    PlaceResult place;
    try {
      place = await GeocodingService.reverse(point);
    } catch (_) {
      place = PlaceResult(
        name: 'Dropped pin',
        address: '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
        point: point,
      );
    }
    if (!mounted) return;
    setState(() => _pending--);
    final side = _pickup == null ? 0 : 1;
    (side == 0 ? _pickupTimer : _dropTimer)?.cancel();
    _ctrl(side).text = place.name;
    _applyPlace(side, place);
  }

  Future<void> _book() async {
    FocusScope.of(context).unfocus();
    _pickupTimer?.cancel();
    _dropTimer?.cancel();

    if (_pickup == null) await _resolve(0);
    if (_dropoff == null) await _resolve(1);
    if (!mounted) return;

    if (!_hasRoute) {
      showSnack(context, 'Type a pick-up and drop-off address.');
      return;
    }
    final fare = _fare;
    final orderId = await DBHelper.instance.insertOrder(
      _pickup!.name,
      _dropoff!.name,
      'P$fare',
      _pickup!.point,
      _dropoff!.point,
      type: 'eSakay',
    );
    if (!mounted) return;
    _showWaitingModal(context, orderId, _pickup!, _dropoff!, fare);
  }

  void _openRentTricycleModal() {
    int selectedYear = DateTime.now().year;
    int selectedMonth = DateTime.now().month;
    int selectedDay = DateTime.now().day;

    final List<String> months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final List<int> years = [2026, 2027, 2028, 2029, 2030];

    final hoursCtrl = TextEditingController();
    final placeCtrl = TextEditingController();

    Widget buildCalendarGrid(int year, int month, StateSetter setModalState) {
      final firstDayOfMonth = DateTime(year, month, 1);
      final lastDayOfMonth = DateTime(year, month + 1, 0);
      final daysInMonth = lastDayOfMonth.day;
      int startingWeekday = firstDayOfMonth.weekday % 7;

      List<Widget> dayWidgets = [];
      for (var d in ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa']) {
        dayWidgets.add(Center(child: Text(d, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: AppColors.navy))));
      }

      for (int i = 0; i < startingWeekday; i++) {
        dayWidgets.add(const SizedBox());
      }

      for (int day = 1; day <= daysInMonth; day++) {
        final isSelected = selectedDay == day;
        dayWidgets.add(
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setModalState(() {
                selectedDay = day;
              });
            },
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.teal : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? Colors.white : (themeManager.isDarkMode ? Colors.white : AppColors.navy),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      return GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: dayWidgets,
      );
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Rent tricycle', style: heading(20)),
                const SizedBox(height: 4),
                const Text('Reserve a driver for a few hours.', style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 16),
                
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: selectedMonth,
                        dropdownColor: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white,
                        items: List.generate(12, (index) => DropdownMenuItem(
                          value: index + 1,
                          child: Text(months[index], style: const TextStyle(fontSize: 13)),
                        )),
                        onChanged: (val) {
                          setModalState(() {
                            selectedMonth = val ?? selectedMonth;
                            selectedDay = 1;
                          });
                        },
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: AppColors.field,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: DropdownButtonFormField<int>(
                        value: selectedYear,
                        dropdownColor: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white,
                        items: years.map((y) => DropdownMenuItem(value: y, child: Text(y.toString(), style: const TextStyle(fontSize: 13)))).toList(),
                        onChanged: (val) {
                          setModalState(() {
                            selectedYear = val ?? selectedYear;
                            selectedDay = 1;
                          });
                        },
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: AppColors.field,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    children: [
                      Text('${months[selectedMonth - 1]} $selectedDay, $selectedYear', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.navy)),
                      const SizedBox(height: 8),
                      buildCalendarGrid(selectedYear, selectedMonth, setModalState),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                AppField(controller: hoursCtrl, hint: 'Hours', icon: Icons.access_time_rounded),
                AppField(controller: placeCtrl, hint: 'Pick-up place', icon: Icons.location_on_outlined),
                const SizedBox(height: 16),
                PillButton(
                  label: 'Request rental (${months[selectedMonth - 1]} $selectedDay, $selectedYear)',
                  onPressed: () async {
                    if (placeCtrl.text.isEmpty || hoursCtrl.text.isEmpty) {
                      showSnack(context, 'Please fill out all fields.');
                      return;
                    }
                    final drop = PlaceResult(name: 'Hourly Rental Destination', address: 'Custom Rental', point: _defaultCenter);
                    final pick = PlaceResult(name: placeCtrl.text, address: 'Rental Pickup', point: _defaultCenter);
                    await DBHelper.instance.insertOrder(pick.name, drop.name, 'P360', pick.point, drop.point, type: 'Rent');
                    Navigator.pop(context);
                    showSnack(context, 'Rental requested for ${months[selectedMonth - 1]} $selectedDay, $selectedYear successfully!');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openScheduleTripModal() {
    int selectedYear = DateTime.now().year;
    int selectedMonth = DateTime.now().month;
    int selectedDay = DateTime.now().day;
    int selectedPassengers = 1;

    final List<String> months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final List<int> years = [2026, 2027, 2028, 2029, 2030];

    final timeCtrl = TextEditingController();
    final destinationCtrl = TextEditingController();

    Widget buildCalendarGrid(int year, int month, StateSetter setModalState) {
      final firstDayOfMonth = DateTime(year, month, 1);
      final lastDayOfMonth = DateTime(year, month + 1, 0);
      final daysInMonth = lastDayOfMonth.day;
      int startingWeekday = firstDayOfMonth.weekday % 7;

      List<Widget> dayWidgets = [];
      for (var d in ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa']) {
        dayWidgets.add(Center(child: Text(d, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: AppColors.navy))));
      }

      for (int i = 0; i < startingWeekday; i++) {
        dayWidgets.add(const SizedBox());
      }

      for (int day = 1; day <= daysInMonth; day++) {
        final isSelected = selectedDay == day;
        dayWidgets.add(
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setModalState(() {
                selectedDay = day;
              });
            },
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.teal : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? Colors.white : (themeManager.isDarkMode ? Colors.white : AppColors.navy),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      return GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: dayWidgets,
      );
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Schedule trip', style: heading(20)),
                const SizedBox(height: 4),
                const Text('Plan a future ride in advance.', style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 16),
                
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: selectedMonth,
                        dropdownColor: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white,
                        items: List.generate(12, (index) => DropdownMenuItem(
                          value: index + 1,
                          child: Text(months[index], style: const TextStyle(fontSize: 13)),
                        )),
                        onChanged: (val) {
                          setModalState(() {
                            selectedMonth = val ?? selectedMonth;
                            selectedDay = 1;
                          });
                        },
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: AppColors.field,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: DropdownButtonFormField<int>(
                        value: selectedYear,
                        dropdownColor: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white,
                        items: years.map((y) => DropdownMenuItem(value: y, child: Text(y.toString(), style: const TextStyle(fontSize: 13)))).toList(),
                        onChanged: (val) {
                          setModalState(() {
                            selectedYear = val ?? selectedYear;
                            selectedDay = 1;
                          });
                        },
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: AppColors.field,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    children: [
                      Text('${months[selectedMonth - 1]} $selectedDay, $selectedYear', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.navy)),
                      const SizedBox(height: 8),
                      buildCalendarGrid(selectedYear, selectedMonth, setModalState),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                AppField(controller: timeCtrl, hint: 'Time', icon: Icons.access_time),
                DropdownButtonFormField<int>(
                  value: selectedPassengers,
                  dropdownColor: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white,
                  items: [1, 2, 3, 4, 5].map((p) => DropdownMenuItem(
                    value: p,
                    child: Text('$p ${p == 1 ? 'passenger' : 'passengers'}', style: const TextStyle(fontSize: 13)),
                  )).toList(),
                  onChanged: (val) {
                    setModalState(() {
                      selectedPassengers = val ?? 1;
                    });
                  },
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.field,
                    prefixIcon: const Icon(Icons.groups, size: 18, color: Colors.grey),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 10),
                AppField(controller: destinationCtrl, hint: 'Destination / Place', icon: Icons.place_outlined),
                const SizedBox(height: 16),
                PillButton(
                  label: 'Schedule trip (${months[selectedMonth - 1]} $selectedDay, $selectedYear)',
                  onPressed: () async {
                    if (timeCtrl.text.isEmpty || destinationCtrl.text.isEmpty) {
                      showSnack(context, 'Please fill out all fields including time and destination.');
                      return;
                    }
                    final pick = PlaceResult(name: 'Home', address: 'Home Address', point: _defaultCenter);
                    final drop = PlaceResult(name: destinationCtrl.text, address: destinationCtrl.text, point: _defaultCenter);
                    await DBHelper.instance.insertOrder(pick.name, drop.name, 'P40', pick.point, drop.point, type: 'Schedule');
                    Navigator.pop(context);
                    showSnack(context, 'Trip scheduled for ${months[selectedMonth - 1]} $selectedDay, $selectedYear successfully!');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showOptionsMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dashboard Options', style: heading(18)),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Filter Orders by Category:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: ['All', 'eSakay', 'Rent', 'Schedule', 'Cancelled'].map((category) {
                return ChoiceChip(
                  label: Text(category),
                  selected: false,
                  onSelected: (_) {
                    Navigator.pop(context);
                    if (widget.onFilterSelected != null) {
                      widget.onFilterSelected!(category);
                    }
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField({
    required TextEditingController ctrl,
    required FocusNode focus,
    required String hint,
    required Color dotColor,
    required int side,
    required PlaceResult? place,
    required String? error,
  }) {
    final noBorder = OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none);
    return TextField(
      controller: ctrl,
      focusNode: focus,
      textInputAction: side == 0 ? TextInputAction.next : TextInputAction.search,
      style: const TextStyle(fontSize: 14, color: AppColors.navy),
      onChanged: (v) => _onTextChanged(side, v),
      onSubmitted: (_) => _onSubmitted(side),
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.field,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
        prefixIcon: Icon(Icons.circle, size: 12, color: dotColor),
        suffixIcon: ctrl.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => _clearField(side),
              ),
        helperText: place?.address,
        helperMaxLines: 1,
        helperStyle: const TextStyle(fontSize: 11, color: Colors.black54),
        errorText: error,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: noBorder,
        enabledBorder: noBorder,
        focusedBorder: noBorder,
      ),
    );
  }

  Widget _topCard() {
    final name = userProfile.fullName.isNotEmpty ? userProfile.fullName : 'Commuter';
    return Material(
      color: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      elevation: 8,
      shadowColor: AppColors.navy.withValues(alpha: 0.2),
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.sky,
                    backgroundImage: userProfile.profilePhoto.isNotEmpty
                        ? (kIsWeb ? NetworkImage(userProfile.profilePhoto) : FileImage(File(userProfile.profilePhoto)) as ImageProvider)
                        : null,
                    child: userProfile.profilePhoto.isEmpty ? const Icon(Icons.electric_rickshaw, color: AppColors.navy) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Where?', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        Text(name, style: heading(16), overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.sort_rounded, color: AppColors.navy),
                    onPressed: () => _showOptionsMenu(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        side: const BorderSide(color: AppColors.teal),
                      ),
                      icon: const Icon(Icons.access_time, size: 16, color: AppColors.teal),
                      label: const Text('Rent Tricycle', style: TextStyle(fontSize: 12, color: AppColors.teal)),
                      onPressed: _openRentTricycleModal,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        side: const BorderSide(color: AppColors.coral),
                      ),
                      icon: const Icon(Icons.calendar_month, size: 16, color: AppColors.coral),
                      label: const Text('Schedule Trip', style: TextStyle(fontSize: 12, color: AppColors.coral)),
                      onPressed: _openScheduleTripModal,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _searchField(
                ctrl: _pickupCtrl,
                focus: _pickupFocus,
                hint: 'Type pick-up address',
                dotColor: AppColors.teal,
                side: 0,
                place: _pickup,
                error: _pickupError,
              ),
              const SizedBox(height: 8),
              _searchField(
                ctrl: _dropCtrl,
                focus: _dropFocus,
                hint: 'Type drop-off address',
                dotColor: AppColors.coral,
                side: 1,
                place: _dropoff,
                error: _dropError,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _defaultCenter,
              initialZoom: 16,
              onLongPress: (tapPosition, latLng) => _onMapLongPress(latLng),
            ),
            children: [
              mapTiles(),
              if (_hasRoute)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [_pickup!.point, _dropoff!.point],
                      color: AppColors.teal,
                      strokeWidth: 4,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_myLocation != null)
                    Marker(point: _myLocation!, width: 44, height: 44, child: const MyLocationDot()),
                  if (_pickup != null)
                    Marker(point: _pickup!.point, width: 44, height: 44, child: const OriginDot()),
                  if (_dropoff != null)
                    Marker(point: _dropoff!.point, width: 56, height: 56, child: const DestPin()),
                ],
              ),
              mapAttribution(),
            ],
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: _topCard()),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: PillButton(
            label: _hasRoute ? 'Take me there!  •  P$_fare' : 'Take me there!',
            onPressed: _book,
          ),
        ),
      ],
    );
  }

  void _showWaitingModal(BuildContext context, int orderId, PlaceResult pickup, PlaceResult dropoff, int fare) {
    Timer? timer;
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (modalContext) {
        timer?.cancel();
        timer = Timer.periodic(const Duration(seconds: 2), (t) async {
          final order = await DBHelper.instance.getOrderById(orderId);
          if (order != null && order['status'] == 'Ongoing') {
            t.cancel();
            if (modalContext.mounted) {
              Navigator.pop(modalContext);
              _showActiveTripModal(context, order['driverName'].toString(), pickup, dropoff, fare, orderId);
            }
          }
        });
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TricycleIllustration(width: 150),
              const SizedBox(height: 12),
              const CircularProgressIndicator(color: AppColors.teal),
              const SizedBox(height: 16),
              Text('Looking for a driver...', style: heading(16)),
              const SizedBox(height: 20),
              PillButton(
                label: 'Cancel booking',
                color: AppColors.coral,
                onPressed: () async {
                  timer?.cancel();
                  await DBHelper.instance.updateOrderStatus(orderId, 'Cancelled');
                  if (modalContext.mounted) Navigator.pop(modalContext);
                  showSnack(context, 'Booking cancelled.');
                },
              ),
            ],
          ),
        );
      },
    ).whenComplete(() => timer?.cancel());
  }

  void _showActiveTripModal(BuildContext context, String driverName, PlaceResult pickup, PlaceResult dropoff, int fare, int orderId) {
    Timer? completionTimer;
    final LatLng pickupCoords = pickup.point;
    const LatLng driverCoords = LatLng(14.2260, 120.9760);

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (modalContext) {
        completionTimer?.cancel();
        completionTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
          final order = await DBHelper.instance.getOrderById(orderId);
          if (order != null && order['status'] == 'Completed') {
            t.cancel();
            if (modalContext.mounted) {
              Navigator.pop(modalContext);
              _showRatingModal(context, driverName);
            }
          }
        });
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Active Ride with $driverName', style: heading(16)),
              const SizedBox(height: 10),
              RouteMap(driver: driverCoords, pickup: pickupCoords, height: 160),
              const SizedBox(height: 10),
              Text('Destination: ${dropoff.name} • P$fare', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        );
      },
    ).whenComplete(() => completionTimer?.cancel());
  }

  void _showRatingModal(BuildContext context, String driverName) {
    int rating = 5;
    final commentCtrl = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Rate $driverName', style: heading(18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) => IconButton(
                  icon: Icon(
                    index < rating ? Icons.star_rounded : Icons.star_border_rounded,
                    color: AppColors.yellow,
                    size: 32,
                  ),
                  onPressed: () => setDialogState(() => rating = index + 1),
                )),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: commentCtrl,
                decoration: InputDecoration(
                  hintText: 'Add a comment (optional)',
                  filled: true,
                  fillColor: AppColors.field,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.navy),
              onPressed: () {
                Navigator.pop(dContext);
                showSnack(context, 'Thank you for your $rating-star rating!');
              },
              child: const Text('Submit rating', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

class OrdersScreen extends StatefulWidget {
  final String initialFilter;
  const OrdersScreen({super.key, this.initialFilter = 'All'});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late String _activeFilter;

  @override
  void initState() {
    super.initState();
    _activeFilter = widget.initialFilter;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.yellow,
        title: Text('Orders', style: heading(20)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['All', 'eSakay', 'Rent', 'Schedule', 'Cancelled'].map((type) {
                  final isSelected = _activeFilter == type;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(type),
                      selected: isSelected,
                      selectedColor: AppColors.teal,
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.white : AppColors.navy,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _activeFilter = type);
                        }
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: DBHelper.instance.getOrders(filterType: _activeFilter),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.teal));
                final orders = snapshot.data as List<dynamic>;
                if (orders.isEmpty) {
                  return Center(child: Text('No $_activeFilter bookings yet.', style: heading(16)));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: orders.length,
                  itemBuilder: (context, index) {
                    final order = orders[index] as Map<String, dynamic>;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${order['pickup']} → ${order['dropoff']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.navy)),
                                const SizedBox(height: 2),
                                Text('Type: ${order['orderType']} • ${order['fare']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              ],
                            ),
                          ),
                          StatusChip(order['status'].toString()),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ConcernsScreen extends StatelessWidget {
  const ConcernsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.yellow, title: Text('Concerns & Contacts', style: heading(20))),
      // Ibinalik sa kaliwa (Left-aligned) ang listahan at title nito
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Support Channels', style: heading(16)),
          const SizedBox(height: 12),
          const ListTile(
            leading: Icon(Icons.email_outlined),
            title: Text('Email Support'),
            subtitle: Text('support@esakaytoda.ph'),
          ),
          const ListTile(
            leading: Icon(Icons.facebook),
            title: Text('Facebook Page'),
            subtitle: Text('fb.com/esakaytoda'),
          ),
          const ListTile(
            leading: Icon(Icons.phone),
            title: Text('Hotline Number'),
            subtitle: Text('0995-535-2737'),
          ),
        ],
      ),
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _nameCtrl = TextEditingController(text: userProfile.fullName);
  final _mobileCtrl = TextEditingController(text: userProfile.mobile);
  final _emailCtrl = TextEditingController(text: userProfile.email);
  String _gender = userProfile.gender;
  String _profilePhoto = userProfile.profilePhoto;

  final ImagePicker _picker = ImagePicker();

  Future<void> _pickProfilePhoto() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (image != null) {
      setState(() => _profilePhoto = image.path);
      showSnack(context, 'Profile photo selected!');
    }
  }

  void _saveProfile() async {
    await DBHelper.instance.updateUserProfile(_emailCtrl.text, _nameCtrl.text, _mobileCtrl.text, _gender, _profilePhoto, userProfile.licensePhoto);
    userProfile.updateProfile(_nameCtrl.text, _emailCtrl.text, phone: _mobileCtrl.text, g: _gender, photo: _profilePhoto, licensePhoto: userProfile.licensePhoto);
    showSnack(context, 'Profile updated successfully!');
  }

  void _confirmDeleteAccount() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Account', style: heading(18, color: AppColors.coral)),
        content: const Text('Deleting removes your profile and ride history. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.coral),
            onPressed: () async {
              await DBHelper.instance.deleteUserAccount(userProfile.email);
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                (route) => false,
              );
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showPolicyDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: heading(18)),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.yellow, title: Text('Account', style: heading(20))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 46,
                  backgroundColor: AppColors.sky,
                  backgroundImage: _profilePhoto.isNotEmpty
                      ? (kIsWeb ? NetworkImage(_profilePhoto) : FileImage(File(_profilePhoto)) as ImageProvider)
                      : null,
                  child: _profilePhoto.isEmpty ? const Icon(Icons.person_rounded, size: 46, color: AppColors.navy) : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.navy,
                    child: IconButton(
                      icon: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                      onPressed: _pickProfilePhoto,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppField(controller: _nameCtrl, hint: 'Full name', icon: Icons.person),
          AppField(controller: _mobileCtrl, hint: 'Mobile number', icon: Icons.phone),
          AppField(controller: _emailCtrl, hint: 'Email', icon: Icons.email),
          DropdownButtonFormField<String>(
            value: _gender.isNotEmpty ? _gender : 'Not specified',
            items: ['Not specified', 'Female', 'Male'].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            onChanged: (val) => setState(() => _gender = val ?? 'Not specified'),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.field,
              prefixIcon: const Icon(Icons.transgender, size: 18, color: Colors.grey),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          PillButton(label: 'Save profile changes', onPressed: _saveProfile),
          const Divider(height: 40),
          SwitchListTile(
            title: const Text('Dark Mode'),
            value: themeManager.isDarkMode,
            onChanged: (val) => themeManager.toggleTheme(val),
          ),
          ListTile(
            leading: const Icon(Icons.description),
            title: const Text('Terms and Conditions'),
            onTap: () => _showPolicyDialog('Terms and Conditions', 'By using eSakay TODA, you agree to follow community safety and booking rules.'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip),
            title: const Text('Privacy Policy'),
            onTap: () => _showPolicyDialog('Privacy Policy', 'Your personal data is safely protected and used solely for dispatch and ride verification.'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: AppColors.coral),
            title: const Text('Delete account', style: TextStyle(color: AppColors.coral)),
            onTap: _confirmDeleteAccount,
          ),
          const SizedBox(height: 20),
          PillButton(
            label: 'Sign out',
            color: AppColors.coral,
            icon: Icons.logout_rounded,
            onPressed: () async {
              await DBHelper.instance.clearSession();
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
    );
  }
}

class DriverDashboard extends StatefulWidget {
  const DriverDashboard({super.key});

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final List<Widget> driverTabs = [
      const DriverHomeTab(),
      const DriverAccountTab(),
    ];

    return Scaffold(
      body: driverTabs[_currentIndex],
      bottomNavigationBar: NavigationBar(
        backgroundColor: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
        indicatorColor: AppColors.yellow,
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.electric_rickshaw_outlined),
            selectedIcon: Icon(Icons.electric_rickshaw_rounded),
            label: 'Queue & Rides',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Driver Account',
          ),
        ],
      ),
    );
  }
}

class DriverHomeTab extends StatefulWidget {
  const DriverHomeTab({super.key});

  @override
  State<DriverHomeTab> createState() => _DriverHomeTabState();
}

class _DriverHomeTabState extends State<DriverHomeTab> {
  bool isOnline = true;
  static const LatLng _driverCoords = LatLng(14.2260, 120.9760);

  String get _name => userProfile.fullName.isNotEmpty ? userProfile.fullName : 'Driver';

  LatLng _pickupOf(Map<String, dynamic> order) {
    final lat = order['pickupLat'];
    final lng = order['pickupLng'];
    if (lat is num && lng is num) return LatLng(lat.toDouble(), lng.toDouble());
    return LocationUtils.getCoords(order['pickup'].toString());
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sign Out', style: heading(18)),
        content: const Text('Are you sure you want to sign out of your driver account?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.coral),
            onPressed: () async {
              await DBHelper.instance.clearSession();
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                (route) => false,
              );
            },
            child: const Text('Sign Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.yellow,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 16, 18),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('eSakay TODA Driver', style: heading(16, color: AppColors.navy)),
                      IconButton(
                        icon: const Icon(Icons.logout_rounded, color: AppColors.navy),
                        onPressed: _confirmLogout,
                        tooltip: 'Sign Out',
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Good day', style: TextStyle(fontSize: 13, color: Colors.black54)),
                              Text(_name, style: heading(24), overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        Text(
                          isOnline ? 'Online' : 'Offline',
                          style: TextStyle(fontWeight: FontWeight.bold, color: isOnline ? AppColors.navy : AppColors.coral),
                        ),
                        Switch(
                          value: isOnline,
                          activeThumbColor: Colors.white,
                          activeTrackColor: AppColors.navy,
                          onChanged: (val) => setState(() => isOnline = val),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
              child: Container(
                width: double.infinity,
                color: themeManager.isDarkMode ? const Color(0xFF1E1E1E) : AppColors.cream,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: isOnline ? _onlineContent() : _offlineContent(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _offlineContent() {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          const TricycleIllustration(width: 220),
          const SizedBox(height: 20),
          Text('You are offline', style: heading(22)),
          const SizedBox(height: 8),
          const Text(
            'Toggle online to receive dispatches and view rent or scheduled trips.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _onlineContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white, borderRadius: BorderRadius.circular(24)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Queue Status', style: heading(16)),
              const SizedBox(height: 4),
              const Text('You are successfully active in the TODA dispatch queue.', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FutureBuilder(
          future: DBHelper.instance.getDriverAcceptedOrders(_name),
          builder: (context, snapshot) {
            final data = snapshot.hasData ? snapshot.data as List<dynamic> : <dynamic>[];
            final trips = data.where((o) => o['status'] == 'Ongoing').toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Active / Dispatched Rides', style: heading(16)),
                const SizedBox(height: 10),
                if (!snapshot.hasData)
                  const Center(child: CircularProgressIndicator(color: AppColors.teal))
                else if (trips.isNotEmpty)
                  _activeTripCard(trips.first as Map<String, dynamic>)
                else
                  _pendingSection(),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _activeTripCard(Map<String, dynamic> trip) {
    final LatLng pickupCoords = _pickupOf(trip);
    final String distanceInfo = LocationUtils.calculateDistanceInfo(_driverCoords, pickupCoords);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Navigate to pickup: $distanceInfo', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 10),
          RouteMap(driver: _driverCoords, pickup: pickupCoords, height: 180),
          const SizedBox(height: 12),
          Text('${trip['pickup']} → ${trip['dropoff']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text('Type: ${trip['orderType']} • Fare: ${trip['fare']}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 14),
          PillButton(
            label: 'Complete Trip',
            onPressed: () async {
              final idVal = int.parse(trip['id'].toString());
              await DBHelper.instance.updateOrderStatus(idVal, 'Completed');
              setState(() {});
              if (!mounted) return;
              showSnack(context, 'Trip marked as completed!');
            },
          ),
        ],
      ),
    );
  }

  Widget _pendingSection() {
    return FutureBuilder(
      future: DBHelper.instance.getPendingBookings(),
      builder: (context, pendingSnapshot) {
        if (!pendingSnapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.teal));
        final pendings = pendingSnapshot.data as List<dynamic>;
        if (pendings.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white, borderRadius: BorderRadius.circular(24)),
            child: const Text('No pending dispatches right now. Waiting for queue...', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          );
        }

        final req = pendings.first as Map<String, dynamic>;
        final LatLng pickupCoords = _pickupOf(req);
        final String distanceInfo = LocationUtils.calculateDistanceInfo(_driverCoords, pickupCoords);

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: themeManager.isDarkMode ? const Color(0xFF2C2C2C) : Colors.white, borderRadius: BorderRadius.circular(24)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: AppColors.yellow, borderRadius: BorderRadius.circular(20)),
                    child: Text('New ${req['orderType']} booking', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.navy)),
                  ),
                  Text(req['fare'].toString(), style: heading(22)),
                ],
              ),
              const SizedBox(height: 12),
              Text(distanceInfo, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 10),
              RouteMap(driver: _driverCoords, pickup: pickupCoords, height: 150, showRoute: false),
              const SizedBox(height: 10),
              Text('${req['pickup']} → ${req['dropoff']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.coral,
                          side: const BorderSide(color: AppColors.coral, width: 2),
                          shape: const StadiumBorder(),
                        ),
                        onPressed: () async {
                          final idVal = int.parse(req['id'].toString());
                          await DBHelper.instance.updateOrderStatus(idVal, 'Cancelled');
                          setState(() {});
                        },
                        child: Text('Decline', style: heading(15, color: AppColors.coral)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PillButton(
                      label: 'Accept',
                      onPressed: () async {
                        final idVal = int.parse(req['id'].toString());
                        await DBHelper.instance.acceptOrder(idVal, _name);
                        setState(() {});
                        if (!context.mounted) return;
                        showSnack(context, 'Booking accepted! Trip is now Ongoing.');
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class DriverAccountTab extends StatefulWidget {
  const DriverAccountTab({super.key});

  @override
  State<DriverAccountTab> createState() => _DriverAccountTabState();
}

class _DriverAccountTabState extends State<DriverAccountTab> {
  final _nameCtrl = TextEditingController(text: userProfile.fullName);
  final _mobileCtrl = TextEditingController(text: userProfile.mobile);
  final _emailCtrl = TextEditingController(text: userProfile.email);
  String _gender = userProfile.gender;
  String _profilePhoto = userProfile.profilePhoto;
  String _licensePhoto = userProfile.licensePhoto;

  final ImagePicker _picker = ImagePicker();

  Future<void> _pickProfilePhoto() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (image != null) {
      setState(() => _profilePhoto = image.path);
      showSnack(context, 'Driver selfie selected!');
    }
  }

  Future<void> _scanLicensePhoto() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera, imageQuality: 75);
    if (image != null) {
      setState(() => _licensePhoto = image.path);
      showSnack(context, 'Driver license scanned and captured successfully!');
    }
  }

  void _saveProfile() async {
    await DBHelper.instance.updateUserProfile(_emailCtrl.text, _nameCtrl.text, _mobileCtrl.text, _gender, _profilePhoto, _licensePhoto);
    userProfile.updateProfile(_nameCtrl.text, _emailCtrl.text, phone: _mobileCtrl.text, g: _gender, photo: _profilePhoto, licensePhoto: _licensePhoto);
    showSnack(context, 'Driver profile & license updated successfully!');
  }

  void _confirmDeleteAccount() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Account', style: heading(18, color: AppColors.coral)),
        content: const Text('Deleting removes your driver profile and history. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.coral),
            onPressed: () async {
              await DBHelper.instance.deleteUserAccount(userProfile.email);
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                (route) => false,
              );
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showPolicyDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: heading(18)),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.yellow, title: Text('Driver Account', style: heading(20))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 46,
                  backgroundColor: AppColors.sky,
                  backgroundImage: _profilePhoto.isNotEmpty
                      ? (kIsWeb ? NetworkImage(_profilePhoto) : FileImage(File(_profilePhoto)) as ImageProvider)
                      : null,
                  child: _profilePhoto.isEmpty ? const Icon(Icons.electric_rickshaw, size: 40, color: AppColors.navy) : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.navy,
                    child: IconButton(
                      icon: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                      onPressed: _pickProfilePhoto,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppField(controller: _nameCtrl, hint: 'Full name', icon: Icons.person),
          AppField(controller: _mobileCtrl, hint: 'Mobile number', icon: Icons.phone, keyboard: TextInputType.phone),
          AppField(controller: _emailCtrl, hint: 'Email', icon: Icons.email, keyboard: TextInputType.emailAddress),
          DropdownButtonFormField<String>(
            value: _gender.isNotEmpty ? _gender : 'Not specified',
            items: ['Not specified', 'Female', 'Male'].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            onChanged: (val) => setState(() => _gender = val ?? 'Not specified'),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.field,
              prefixIcon: const Icon(Icons.transgender, size: 18, color: Colors.grey),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 16),
          Text("Driver's License Photo / Scan", style: heading(14)),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _scanLicensePhoto,
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                color: AppColors.field,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade300),
                image: _licensePhoto.isNotEmpty
                    ? DecorationImage(
                        image: (kIsWeb ? NetworkImage(_licensePhoto) : FileImage(File(_licensePhoto)) as ImageProvider),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _licensePhoto.isEmpty
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_enhance_rounded, size: 36, color: AppColors.teal),
                        SizedBox(height: 8),
                        Text('Tap to scan / take photo of license', style: TextStyle(color: Colors.grey, fontSize: 13)),
                      ],
                    )
                  : Align(
                      alignment: Alignment.topRight,
                      child: Container(
                        margin: const EdgeInsets.all(8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: const Text('Retake photo', style: TextStyle(color: Colors.white, fontSize: 11)),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          PillButton(label: 'Save profile changes', onPressed: _saveProfile),
          const Divider(height: 40),
          SwitchListTile(
            title: const Text('Dark Mode'),
            value: themeManager.isDarkMode,
            onChanged: (val) => themeManager.toggleTheme(val),
          ),
          ListTile(
            leading: const Icon(Icons.description),
            title: const Text('Driver Terms and Conditions'),
            onTap: () => _showPolicyDialog(
              'Driver Terms and Conditions',
              'As an eSakay TODA driver, you agree to follow dispatch queues, maintain safe driving speeds, respect passengers, and comply with all local TODA regulations.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip),
            title: const Text('Privacy Policy'),
            onTap: () => _showPolicyDialog(
              'Privacy Policy',
              'Your location data, license details, and ride logs are securely used solely for dispatch queue management and ride tracking.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: AppColors.coral),
            title: const Text('Delete account', style: TextStyle(color: AppColors.coral)),
            onTap: _confirmDeleteAccount,
          ),
          const SizedBox(height: 20),
          PillButton(
            label: 'Sign out',
            color: AppColors.coral,
            icon: Icons.logout_rounded,
            onPressed: () async {
              await DBHelper.instance.clearSession();
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
    );
  }
}