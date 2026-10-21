import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const EsqScannerApp());

const Color esqRed = Color(0xFFB91C1C);
const Color ink = Color(0xFF171717);
const Color canvas = Color(0xFFF5F6F8);
const Color muted = Color(0xFF6B7280);

class EsqScannerApp extends StatelessWidget {
  const EsqScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESQ Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: esqRed),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        ),
      ),
      home: const ScannerHome(),
    );
  }
}

enum CheckInStatus { success, alreadyCheckedIn, invalid, error }

class CheckInResult {
  const CheckInResult({
    required this.status,
    required this.message,
    this.participantName,
    this.participantId,
    this.checkedInAt,
  });

  final CheckInStatus status;
  final String message;
  final String? participantName;
  final String? participantId;
  final DateTime? checkedInAt;
}

class AttendanceService {
  static const String apiBaseUrl = String.fromEnvironment(
    'ATTENDANCE_API_URL',
    defaultValue: '',
  );

  Future<CheckInResult> checkIn(String qrValue) async {
    if (apiBaseUrl.isEmpty) {
      return CheckInResult(
        status: CheckInStatus.error,
        message: 'API belum ditetapkan. Kehadiran belum direkodkan.',
        participantId: qrValue,
      );
    }
    try {
      final response = await http
          .post(
            Uri.parse(apiBaseUrl),
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'qr': qrValue, 'action': 'check_in'}),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return CheckInResult(
          status: CheckInStatus.error,
          message: 'Ralat pelayan (${response.statusCode}). Cuba sekali lagi.',
        );
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final ok = data['success'] == true || data['status'] == 'success';
      final already = data['already_checked_in'] == true || data['status'] == 'already_checked_in';
      return CheckInResult(
        status: already ? CheckInStatus.alreadyCheckedIn : ok ? CheckInStatus.success : CheckInStatus.invalid,
        message: (data['message'] ?? (already
                ? 'Peserta sudah direkodkan hadir.'
                : ok
                    ? 'Kehadiran berjaya disahkan.'
                    : 'QR tidak sah atau peserta tidak ditemui.'))
            .toString(),
        participantName: (data['participant_name'] ?? data['name'])?.toString(),
        participantId: (data['participant_id'] ?? data['id'])?.toString(),
        checkedInAt: DateTime.tryParse((data['checked_in_at'] ?? '').toString()),
      );
    } on TimeoutException {
      return const CheckInResult(status: CheckInStatus.error, message: 'Sambungan perlahan. Sila cuba lagi.');
    } catch (_) {
      return const CheckInResult(status: CheckInStatus.error, message: 'Tidak dapat menghubungi sistem. Semak internet/API.');
    }
  }
}

class ScannerHome extends StatefulWidget {
  const ScannerHome({super.key});

  @override
  State<ScannerHome> createState() => _ScannerHomeState();
}

class _ScannerHomeState extends State<ScannerHome> with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
  );
  final AttendanceService _service = AttendanceService();

  bool _processing = false;
  bool _torchOn = false;
  bool _paused = false;
  String? _lastRawValue;
  DateTime? _lastScanAt;
  int _successCount = 0;
  int _alreadyCount = 0;
  int _errorCount = 0;
  CheckInResult? _lastResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCounters();
  }

  Future<void> _loadCounters() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _successCount = prefs.getInt('successCount') ?? 0;
      _alreadyCount = prefs.getInt('alreadyCount') ?? 0;
      _errorCount = prefs.getInt('errorCount') ?? 0;
    });
  }

  Future<void> _saveCounters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('successCount', _successCount);
    await prefs.setInt('alreadyCount', _alreadyCount);
    await prefs.setInt('errorCount', _errorCount);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _controller.stop();
    } else if (state == AppLifecycleState.resumed && !_paused && mounted) {
      _controller.start();
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || _paused) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    final now = DateTime.now();
    if (_lastRawValue == raw && _lastScanAt != null && now.difference(_lastScanAt!) < const Duration(seconds: 3)) return;

    _processing = true;
    _lastRawValue = raw;
    _lastScanAt = now;
    await _controller.stop();

    final result = await _service.checkIn(raw);
    if (!mounted) return;
    setState(() {
      _lastResult = result;
      switch (result.status) {
        case CheckInStatus.success:
          _successCount++;
          break;
        case CheckInStatus.alreadyCheckedIn:
          _alreadyCount++;
          break;
        case CheckInStatus.invalid:
        case CheckInStatus.error:
          _errorCount++;
          break;
      }
    });
    await _saveCounters();
    await Future<void>.delayed(const Duration(milliseconds: 1250));
    if (!mounted || _paused) return;
    setState(() => _lastResult = null);
    _processing = false;
    await _controller.start();
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  Future<void> _togglePause() async {
    setState(() => _paused = !_paused);
    if (_paused) {
      await _controller.stop();
    } else {
      setState(() => _lastResult = null);
      _processing = false;
      await _controller.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _lastResult;
    final resultColor = result == null
        ? Colors.transparent
        : result.status == CheckInStatus.success
            ? const Color(0xFF15803D)
            : result.status == CheckInStatus.alreadyCheckedIn
                ? const Color(0xFFB45309)
                : const Color(0xFFB91C1C);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: Row(
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(color: esqRed, borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 27),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ESQ SCANNER', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: .3)),
                  SizedBox(height: 2),
                  Text('Pengesahan kehadiran', style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(30)),
              child: Row(
                children: [
                  Container(width: 7, height: 7, decoration: const BoxDecoration(color: Color(0xFF16A34A), shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  const Text('CREW', style: TextStyle(color: Color(0xFF166534), fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .8)),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  _statCard('BERJAYA', _successCount, const Color(0xFF15803D), Icons.check_circle_rounded),
                  const SizedBox(width: 8),
                  _statCard('SUDAH HADIR', _alreadyCount, const Color(0xFFB45309), Icons.history_rounded),
                  const SizedBox(width: 8),
                  _statCard('RALAT', _errorCount, const Color(0xFFB91C1C), Icons.error_outline_rounded),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MobileScanner(controller: _controller, onDetect: _onDetect),
                      IgnorePointer(
                        child: Center(
                          child: SizedBox(
                            width: 248,
                            height: 248,
                            child: Stack(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.white.withValues(alpha: .88), width: 2),
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                                for (final alignment in const [
                                  Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight
                                ])
                                  Align(
                                    alignment: alignment,
                                    child: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        border: Border(
                                          top: alignment.y < 0 ? const BorderSide(color: Colors.white, width: 5) : BorderSide.none,
                                          bottom: alignment.y > 0 ? const BorderSide(color: Colors.white, width: 5) : BorderSide.none,
                                          left: alignment.x < 0 ? const BorderSide(color: Colors.white, width: 5) : BorderSide.none,
                                          right: alignment.x > 0 ? const BorderSide(color: Colors.white, width: 5) : BorderSide.none,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 14,
                        left: 14,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: .52), borderRadius: BorderRadius.circular(30)),
                          child: Row(
                            children: [
                              Container(width: 7, height: 7, decoration: const BoxDecoration(color: Color(0xFF4ADE80), shape: BoxShape.circle)),
                              const SizedBox(width: 7),
                              Text(_paused ? 'DIJEDA' : 'KAMERA AKTIF',
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .7)),
                            ],
                          ),
                        ),
                      ),
                      if (_paused)
                        Container(
                          color: Colors.black.withValues(alpha: .78),
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.pause_circle_filled_rounded, color: Colors.white, size: 64),
                                SizedBox(height: 10),
                                Text('IMBASAN DIJEDA', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
                                SizedBox(height: 5),
                                Text('Tekan butang sambung di bawah', style: TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      if (result != null)
                        Container(
                          color: resultColor.withValues(alpha: .96),
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 86,
                                  height: 86,
                                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: .17), shape: BoxShape.circle),
                                  child: Icon(
                                    result.status == CheckInStatus.success
                                        ? Icons.check_rounded
                                        : result.status == CheckInStatus.alreadyCheckedIn
                                            ? Icons.history_rounded
                                            : Icons.priority_high_rounded,
                                    color: Colors.white,
                                    size: 58,
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  result.status == CheckInStatus.success
                                      ? 'KEHADIRAN DISAHKAN'
                                      : result.status == CheckInStatus.alreadyCheckedIn
                                          ? 'PESERTA SUDAH HADIR'
                                          : result.status == CheckInStatus.invalid
                                              ? 'QR TIDAK SAH'
                                              : 'SEMAK SAMBUNGAN',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 21, height: 1.15, fontWeight: FontWeight.w900),
                                ),
                                if (result.participantName != null) ...[
                                  const SizedBox(height: 12),
                                  Text(result.participantName!, textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
                                ],
                                const SizedBox(height: 9),
                                Text(result.message, textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4)),
                                const SizedBox(height: 18),
                                const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                                    SizedBox(width: 9),
                                    Text('Sedia untuk peserta seterusnya…',
                                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                  ],
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 18),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(14)),
                          child: const Icon(Icons.center_focus_strong_rounded, color: esqRed, size: 24),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Sedia untuk scan', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: ink)),
                              SizedBox(height: 3),
                              Text('Halakan kamera ke QR pada tiket peserta.', style: TextStyle(fontSize: 11, color: muted)),
                            ],
                          ),
                        ),
                        Icon(Icons.bolt_rounded, color: Colors.amber.shade700, size: 24),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: _togglePause,
                            icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                            label: Text(_paused ? 'SAMBUNG SCAN' : 'JEDA SCAN'),
                            style: FilledButton.styleFrom(
                              backgroundColor: ink,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 52,
                        width: 56,
                        child: OutlinedButton(
                          onPressed: _toggleTorch,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: ink,
                            side: const BorderSide(color: Color(0xFFE5E7EB)),
                            backgroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            padding: EdgeInsets.zero,
                          ),
                          child: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('ESQ SCANNER  •  CREW CHECK-IN', style: TextStyle(fontSize: 9, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: Color(0xFF9CA3AF))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, int value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFEDEEF1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 8),
            Text('$value', style: TextStyle(fontSize: 23, height: 1, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 5),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 8, letterSpacing: .4, fontWeight: FontWeight.w900, color: muted)),
          ],
        ),
      ),
    );
  }
}
