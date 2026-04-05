import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['Directions', 'Fleet', 'Cards', 'Activity', 'Bookings'];
  static const _superAdminEmail = 'nelsonjembe99@gmail.com';

  late final TabController _tabController;
  final _fx = FirebaseFunctions.instance;
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _superEntityIdCtrl = TextEditingController();
  final _superExportIdCtrl = TextEditingController();
  final _superUserACtrl = TextEditingController();
  final _superUserBCtrl = TextEditingController();

  String? _agencyId;
  String? _role;
  String? _error;
  bool _isSuperAdmin = false;
  bool _enterConsole = false;
  bool _loading = true;
  bool _countsLoading = false;
  Map<String, dynamic>? _systemCounts;
  String _exportResult = '';
  String _superEntityType = 'user';
  bool _superEntityActive = false;
  String _superExportType = 'user';
  String _superExportFormat = 'json';
  String? _softNotice;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadMembership();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _superEntityIdCtrl.dispose();
    _superExportIdCtrl.dispose();
    _superUserACtrl.dispose();
    _superUserBCtrl.dispose();
    super.dispose();
  }

  bool get _isAdmin =>
      _role == 'agency_admin' ||
      _role == 'agency_staff' ||
      _role == 'agency_reader';

  String _norm(String? value) => (value ?? '').trim().toLowerCase();

  bool _belongsToAgencyDoc(String docId, Map<String, dynamic> agencyData) {
    final mine = _norm(_agencyId);
    if (mine.isEmpty) return false;
    final byId = _norm(docId);
    final byName = _norm('${agencyData['name'] ?? ''}');
    final byCode = _norm('${agencyData['code'] ?? ''}');
    return mine == byId || mine == byName || mine == byCode;
  }

  String _shortAdminTag() {
    final user = _auth.currentUser;
    String raw = '';
    if ((user?.displayName ?? '').trim().isNotEmpty) {
      raw = user!.displayName!.trim();
    } else if ((user?.email ?? '').contains('@')) {
      raw = (user?.email ?? '').split('@').first.trim();
    } else {
      raw = (user?.uid ?? 'you').trim();
    }
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return 'you...';
    if (compact.length <= 3) return '$compact...';
    return '${compact.substring(0, 3)}...';
  }

  void _closeSheet<T>(BuildContext context, [T? result]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  String _friendlyError(Object error, {String fallback = 'Something went wrong.'}) {
    if (error is FirebaseFunctionsException) {
      final code = error.code.toLowerCase();
      final details = (error.message ?? '').trim();
      if (code == 'not-found') return 'Feature is not deployed yet.';
      if (code == 'permission-denied') return 'You do not have permission for this action.';
      if (code == 'unauthenticated') return 'Please sign in again and retry.';
      if (details.isNotEmpty) return details;
      return fallback;
    }
    final text = '$error'.replaceAll('\n', ' ').trim();
    if (text.isEmpty) return fallback;
    if (text.length > 140) return '${text.substring(0, 140)}...';
    return text;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    });
  }

  Future<void> _loadMembership() async {
    try {
      final user = _auth.currentUser;
      final uid = user?.uid;
      if (uid == null) {
        setState(() {
          _error = 'Sign in required.';
          _loading = false;
        });
        return;
      }

      final email = (user?.email ?? '').toLowerCase();
      if (email == _superAdminEmail) {
        setState(() {
          _isSuperAdmin = true;
          _error = null;
          _loading = false;
        });
        unawaited(_refreshSystemCounts());
        return;
      }

      final doc = await _fs.collection('agency_members').doc(uid).get();
      if (!doc.exists) {
        setState(() {
          _error = null;
          _agencyId = null;
          _role = null;
          _loading = false;
        });
        return;
      }

      final d = doc.data()!;
      if (d['active'] != true) {
        setState(() {
          _error = 'Agency access is inactive.';
          _loading = false;
        });
        return;
      }

      setState(() {
        _agencyId = '${d['agencyId'] ?? ''}'.trim();
        _role = '${d['role'] ?? ''}'.trim().toLowerCase();
        _error = null;
        _enterConsole = false;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _submitAgencyApplication() async {
    String agencyName = '';
    String fleetText = '';
    String fullName = '';
    String phone = '';
    String whatsapp = '';
    String spotlightUsername = '';
    String notes = '';
    String agencyPassword = '';
    final email = _auth.currentUser?.email ?? '';

    final payload = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Register Real Agency',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      'Your email: $email',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => agencyName = v),
                    decoration: const InputDecoration(labelText: 'Agency name'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => setM(() => fleetText = v),
                    decoration: const InputDecoration(labelText: 'Number of cars'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => fullName = v),
                    decoration: const InputDecoration(labelText: 'Your full name'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => phone = v),
                    decoration: const InputDecoration(labelText: 'Phone number'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => whatsapp = v),
                    decoration: const InputDecoration(labelText: 'WhatsApp number'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => spotlightUsername = v),
                    decoration: const InputDecoration(labelText: 'SpotLight username'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    onChanged: (v) => setM(() => notes = v),
                    decoration: const InputDecoration(labelText: 'Extra details (optional)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => agencyPassword = v),
                    decoration: const InputDecoration(
                      labelText: 'Agency entry password',
                      helperText: 'People who belong to this agency will use this to open it.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final fleet = int.tryParse(fleetText.trim());
                        if (agencyName.trim().isEmpty ||
                            fullName.trim().isEmpty ||
                            phone.trim().isEmpty ||
                            spotlightUsername.trim().isEmpty ||
                            agencyPassword.trim().length < 4 ||
                            fleet == null ||
                            fleet <= 0) {
                          return;
                        }
                        _closeSheet(ctx, {
                          'agencyName': agencyName.trim(),
                          'fleetSize': fleet,
                          'fullName': fullName.trim(),
                          'phone': phone.trim(),
                          'whatsapp': whatsapp.trim(),
                          'spotlightUsername': spotlightUsername.trim(),
                          'notes': notes.trim(),
                          'agencyPassword': agencyPassword.trim(),
                        });
                      },
                      child: const Text('Submit Application'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (payload == null) return;
    try {
      final callable = _fx.httpsCallable('submitAgencyApplication');
      await callable.call(payload);
      _showSnack('Application submitted for review.');
    } catch (e) {
      _showSnack('Submit failed: $e');
    }
  }

  Future<void> _approveApplication(String id) async {
    try {
      final callable = _fx.httpsCallable('approveAgencyApplication');
      await callable.call({'applicationId': id});
      _showSnack('Application approved.');
    } catch (e) {
      _showSnack('Approve failed: $e');
    }
  }

  Future<void> _refreshSystemCounts() async {
    if (!_isSuperAdmin) return;
    setState(() => _countsLoading = true);
    try {
      final callable = _fx.httpsCallable('getSystemCounts');
      final res = await callable.call();
      if (!mounted) return;
      setState(() {
        _systemCounts = Map<String, dynamic>.from(res.data as Map);
        _countsLoading = false;
        _softNotice = null;
      });
    } catch (e) {
      if (!mounted) return;
      final message = '$e';
      setState(() {
        _countsLoading = false;
        _softNotice = message.contains('firebase_functions/not-found')
            ? 'System counts are unavailable until the latest Cloud Functions are deployed.'
            : 'System counts could not load right now.';
      });
    }
  }

  void _enterAgencyConsole(String agencyId, String role) {
    if (!mounted) return;
    setState(() {
      _agencyId = agencyId;
      _role = role.trim().toLowerCase();
      _error = null;
      _enterConsole = true;
    });
    unawaited(_syncAgencyBuses());
  }

  Future<void> _syncAgencyBuses() async {
    final aid = _agencyId;
    if (aid == null || aid.isEmpty) return;
    try {
      final callable = _fx.httpsCallable('backfillDiscoveredBuses');
      await callable.call({'agencyId': aid});
    } catch (_) {
      // Best-effort sync only; UI keeps working even if function isn't deployed.
    }
  }

  Future<void> _resolveResetRequest(String id, String status) async {
    try {
      final callable = _fx.httpsCallable('resolveAgencyPasswordReset');
      await callable.call({'requestId': id, 'status': status});
      _showSnack('Request marked $status.');
    } catch (e) {
      _showSnack('Resolve failed: $e');
    }
  }

  Future<void> _setEntityActiveControl({
    required String entityType,
    required String entityId,
    required bool active,
  }) async {
    try {
      final callable = _fx.httpsCallable('setEntityActive');
      await callable.call({
        'entityType': entityType,
        'entityId': entityId,
        'active': active,
      });
      _showSnack('${entityType.toUpperCase()} updated.');
      await _refreshSystemCounts();
    } catch (e) {
      _showSnack('Update failed: $e');
    }
  }

  Future<void> _exportEntity({
    required String entityType,
    required String entityId,
    required String format,
  }) async {
    try {
      final callable = _fx.httpsCallable('exportEntityData');
      final res = await callable.call({
        'entityType': entityType,
        'entityId': entityId,
        'format': format,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      setState(() => _exportResult = '${data['content'] ?? ''}');
      _showSnack('Export ready: ${data['filename']}');
    } catch (e) {
      _showSnack('Export failed: $e');
    }
  }

  Future<void> _exportChat({
    required String userA,
    required String userB,
  }) async {
    try {
      final callable = _fx.httpsCallable('exportChatBetweenUsers');
      final res = await callable.call({
        'userA': userA,
        'userB': userB,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      setState(() => _exportResult = '${data['content'] ?? ''}');
      _showSnack('Chat export ready: ${data['filename']}');
    } catch (e) {
      _showSnack('Chat export failed: $e');
    }
  }

  Future<void> _openAgencyByPassword({
    required String agencyId,
    required bool isDemo,
  }) async {
    String enteredPassword = '';
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isDemo ? 'Open Demo Agency' : 'Open Agency',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                isDemo
                    ? 'Use demopassword to enter demo agency and learn how it works.'
                    : 'Enter this agency password (set by agency admin).',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextField(
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => enteredPassword = v,
                decoration: const InputDecoration(labelText: 'Agency password'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _closeSheet(ctx, {'action': 'open'}),
                  child: const Text('Open'),
                ),
              ),
              if (!isDemo) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _closeSheet(ctx, {'action': 'forgot'}),
                  child: const Text('Forgot agency password?'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    final password = enteredPassword.trim();
    if (result == null) return;
    final action = '${result['action'] ?? ''}';
    if (action == 'forgot') {
      await _requestAgencyPasswordReset(agencyId);
      return;
    }
    if (password.isEmpty) return;

    try {
      final callable = _fx.httpsCallable('openAgencyByPassword');
      final res = await callable.call({
        'agencyId': agencyId,
        'password': password,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      _enterAgencyConsole(
        '${data['agencyId'] ?? agencyId}',
        '${data['role'] ?? _role ?? ''}',
      );
      _showSnack('Agency opened successfully.');
    } catch (e) {
      _showSnack('Open failed: ${_friendlyError(e, fallback: 'Could not open agency.')}');
    }
  }

  Future<void> _requestAgencyPasswordReset(String agencyId) async {
    try {
      final callable = _fx.httpsCallable('requestAgencyPasswordReset');
      final res = await callable.call({'agencyId': agencyId});
      final data = Map<String, dynamic>.from(res.data as Map);
      if ((data['alreadyPending'] ?? false) == true) {
        _showSnack('A reset request is already pending. Super admin will contact you.');
      } else {
        _showSnack('Reset request sent to super admin (nelsonjembe99@gmail.com).');
      }
    } catch (e) {
      _showSnack('Reset request failed: ${_friendlyError(e)}');
    }
  }

  Future<void> _setAgencyPassword() async {
    if (!_isAdmin) return;
    String pass = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Set Agency Password',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'This password is required when opening your agency from the list.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextField(
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => pass = v,
                decoration: const InputDecoration(labelText: 'New agency password'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final p = pass.trim();
                    if (p.length < 4) return;
                    try {
                      final callable = _fx.httpsCallable('setAgencyAccessPassword');
                      await callable.call({'password': p});
                      if (!ctx.mounted) return;
                      _closeSheet(ctx);
                      _showSnack('Agency password updated.');
                    } catch (e) {
                      _showSnack('Failed: $e');
                    }
                  },
                  child: const Text('Save Password'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openBusForm({String? busId, Map<String, dynamic>? existing}) async {
    String idText = busId ?? '';
    String agencyNameText = existing?['agencyName']?.toString() ?? '';
    String plateText = existing?['plateNumber']?.toString() ?? '';
    String capacityText = '${existing?['capacity'] ?? 30}';
    String seatsText = '${existing?['availableSeats'] ?? 0}';
    String secretText = '';
    String routeId = existing?['routeId']?.toString() ?? '';
    bool active = existing?['active'] != false;

    final routeSnap = await _fs
        .collection('routes')
        .where('global', isEqualTo: true)
        .where('active', isEqualTo: true)
        .get();
    final busSnap = await _fs
        .collection('buses')
        .where('agencyId', isEqualTo: _agencyId)
        .limit(200)
        .get();
    if (!mounted) return;
    final routes = routeSnap.docs;
    final discoveredBuses = busSnap.docs;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    busId == null ? 'Add Bus' : 'Edit Bus',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (busId == null && discoveredBuses.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      initialValue: idText.isEmpty ? null : idText,
                      dropdownColor: const Color(0xFF0F172A),
                      decoration: const InputDecoration(
                        labelText: 'Pick discovered bus (by name/plate)',
                      ),
                      items: discoveredBuses
                          .map(
                            (b) => DropdownMenuItem<String>(
                              value: b.id,
                              child: Text(
                                '${b.id} - ${b.data()['plateNumber'] ?? ''} - ${b.data()['agencyName'] ?? ''}',
                                style: const TextStyle(color: Colors.white),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final matched = discoveredBuses.firstWhere((b) => b.id == v).data();
                        setM(() {
                          idText = v;
                          agencyNameText =
                              '${matched['agencyName'] ?? agencyNameText}'.trim();
                          plateText = '${matched['plateNumber'] ?? plateText}'.trim();
                          if ((matched['capacity'] ?? '').toString().isNotEmpty) {
                            capacityText = '${matched['capacity']}';
                          }
                          if ((matched['availableSeats'] ?? '').toString().isNotEmpty) {
                            seatsText = '${matched['availableSeats']}';
                          }
                          if ((matched['routeId'] ?? '').toString().isNotEmpty) {
                            routeId = '${matched['routeId']}';
                          }
                          if (matched['active'] is bool) {
                            active = matched['active'] as bool;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextFormField(
                    initialValue: idText,
                    enabled: busId == null,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => idText = v),
                    decoration: const InputDecoration(labelText: 'Bus ID (matches device key)'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: agencyNameText,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => agencyNameText = v),
                    decoration: const InputDecoration(labelText: 'Agency display name'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: plateText,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => plateText = v),
                    decoration: const InputDecoration(labelText: 'Plate number'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: routeId.isEmpty ? null : routeId,
                    dropdownColor: const Color(0xFF0F172A),
                    decoration: const InputDecoration(labelText: 'Route'),
                    items: routes
                        .map((r) => DropdownMenuItem<String>(
                              value: r.id,
                              child: Text(
                                '${r.data()['origin']} -> ${r.data()['destination']}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setM(() => routeId = v ?? ''),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: capacityText,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => capacityText = v),
                    decoration: const InputDecoration(labelText: 'Capacity'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: seatsText,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => seatsText = v),
                    decoration: const InputDecoration(labelText: 'Available seats'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => secretText = v),
                    decoration: const InputDecoration(
                      labelText: 'Device secret (optional for update)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: active,
                    title: const Text('Active', style: TextStyle(color: Colors.white)),
                    onChanged: (v) => setM(() => active = v),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final cap = int.tryParse(capacityText.trim());
                        final seats = int.tryParse(seatsText.trim());
                        final finalBusId = idText.trim();
                        if (finalBusId.isEmpty || cap == null || seats == null) return;
                        try {
                          final callable = _fx.httpsCallable('createOrUpdateBus');
                          await callable.call({
                            'busId': finalBusId,
                            'agencyName': agencyNameText.trim(),
                            'plateNumber': plateText.trim(),
                            'routeId': routeId,
                            'capacity': cap,
                            'availableSeats': seats,
                            'active': active,
                            if (secretText.trim().isNotEmpty) 'deviceSecret': secretText.trim(),
                          });
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _showSnack('Bus saved.');
                        } catch (e) {
                          if (!ctx.mounted) return;
                          ScaffoldMessenger.maybeOf(ctx)
                              ?.showSnackBar(SnackBar(content: Text('Bus save failed: $e')));
                        }
                      },
                      child: Text(busId == null ? 'Create Bus' : 'Save Bus'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRouteForm({String? routeId, Map<String, dynamic>? existing}) async {
    final originCtrl = TextEditingController(text: existing?['origin']?.toString() ?? '');
    final destCtrl = TextEditingController(text: existing?['destination']?.toString() ?? '');
    final fareCtrl = TextEditingController(text: '${existing?['fareRwf'] ?? ''}');
    bool active = existing?['active'] != false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  routeId == null ? 'Create Route' : 'Update Route',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: originCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(labelText: 'Origin'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: destCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(labelText: 'Destination'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: fareCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(labelText: 'Fare (RWF)'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: active,
                  title: const Text('Active', style: TextStyle(color: Colors.white)),
                  onChanged: (v) => setM(() => active = v),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      final fare = int.tryParse(fareCtrl.text.trim());
                      if (originCtrl.text.trim().isEmpty ||
                          destCtrl.text.trim().isEmpty ||
                          fare == null ||
                          fare < 0) {
                        return;
                      }
                      try {
                        final callable = _fx.httpsCallable('createOrUpdateRoute');
                        await callable.call({
                          'routeId': routeId,
                          'origin': originCtrl.text.trim(),
                          'destination': destCtrl.text.trim(),
                          'fareRwf': fare,
                          'active': active,
                        });
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                      } catch (e) {
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('Route save failed: $e')),
                        );
                      }
                    },
                    child: Text(routeId == null ? 'Create route' : 'Save changes'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    originCtrl.dispose();
    destCtrl.dispose();
    fareCtrl.dispose();
  }

  Future<void> _assignRouteToBus(String busId, String routeId) async {
    try {
      final callable = _fx.httpsCallable('assignRouteToBus');
      await callable.call({'busId': busId, 'routeId': routeId});
      _showSnack('Route assigned successfully.');
    } catch (e) {
      _showSnack('Assign failed: $e');
    }
  }

  Future<void> _topUpCard() async {
    String search = '';
    String? selectedCardId;
    String selectedCardLabel = '';
    String amountText = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setM) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Top Up Card Balance',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => search = v.trim().toLowerCase()),
                  decoration: const InputDecoration(
                    labelText: 'Search card (owner / card id)',
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 170,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs.collection('cards').limit(200).snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: Text(
                            'Could not load cards. ${_friendlyError(snap.error!)}',
                            style: const TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                      }
                      final docs = snap.data!.docs.where((d) {
                        final m = d.data();
                        if (m['active'] != true) return false;
                        if (search.isEmpty) return true;
                        final owner = '${m['ownerName'] ?? m['userId'] ?? ''}'.toLowerCase();
                        final cardId = d.id.toLowerCase();
                        return owner.contains(search) || cardId.contains(search);
                      }).toList();
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text('No active cards found.', style: TextStyle(color: Colors.white70)),
                        );
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i];
                          final m = d.data();
                          final owner = '${m['ownerName'] ?? m['userId'] ?? 'Unknown'}';
                          final label = '$owner - ${d.id} - RWF ${m['balanceRwf'] ?? 0}';
                          final active = selectedCardId == d.id;
                          return ListTile(
                            dense: true,
                            title: Text(
                              label,
                              style: TextStyle(
                                color: active ? const Color(0xFF93C5FD) : Colors.white,
                                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            onTap: () {
                              setM(() {
                                selectedCardId = d.id;
                                selectedCardLabel = label;
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                if (selectedCardId != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Selected: $selectedCardLabel',
                      style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => amountText = v,
                  decoration: const InputDecoration(labelText: 'Amount (RWF)'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      final amount = int.tryParse(amountText.trim());
                      if (selectedCardId == null || amount == null || amount <= 0) {
                        return;
                      }
                      try {
                        final callable = _fx.httpsCallable('topUpCard');
                        final res = await callable.call({
                          'cardId': selectedCardId,
                          'amountRwf': amount,
                        });
                        final data = Map<String, dynamic>.from(res.data as Map);
                        if (!ctx.mounted) return;
                        FocusManager.instance.primaryFocus?.unfocus();
                        Navigator.pop(ctx);
                        _showSnack('Top up success. New balance: RWF ${data['newBalanceRwf']}');
                      } catch (e) {
                        _showSnack('Top up failed: ${_friendlyError(e)}');
                      }
                    },
                    child: const Text('Top up'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _registerCardToUser() async {
    String cardIdText = '';
    String balanceText = '0';
    String search = '';
    String? selectedUserId;
    String selectedUserLabel = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setM) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Register Card To User',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Search user (name / username / email / uid)',
                  ),
                  onChanged: (v) => setM(() => search = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 160,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs.collection('users').limit(120).snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: Text(
                            'Could not load users. ${_friendlyError(snap.error!)}',
                            style: const TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                      }
                      final q = search;
                      final docs = snap.data!.docs.where((d) {
                        if (q.isEmpty) return true;
                        final m = d.data();
                        final display = '${m['displayName'] ?? m['name'] ?? ''}'.toLowerCase();
                        final username = '${m['username'] ?? ''}'.toLowerCase();
                        final email = '${m['email'] ?? ''}'.toLowerCase();
                        final uid = d.id.toLowerCase();
                        return display.contains(q) ||
                            username.contains(q) ||
                            email.contains(q) ||
                            uid.contains(q);
                      }).toList();
                      if (docs.isEmpty) {
                        return const Center(child: Text('No users found.', style: TextStyle(color: Colors.white70)));
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i];
                          final m = d.data();
                          final label = '${m['displayName'] ?? m['name'] ?? 'User'} - ${m['email'] ?? d.id}';
                          final active = selectedUserId == d.id;
                          return ListTile(
                            dense: true,
                            title: Text(
                              label,
                              style: TextStyle(
                                color: active ? const Color(0xFF93C5FD) : Colors.white,
                                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            onTap: () {
                              setM(() {
                                selectedUserId = d.id;
                                selectedUserLabel = label;
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                if (selectedUserId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Selected: $selectedUserLabel',
                      style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => cardIdText = v,
                  decoration: const InputDecoration(labelText: 'Card ID (RFID UID)'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: balanceText,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => balanceText = v,
                  decoration: const InputDecoration(labelText: 'Initial balance (RWF)'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final amount = int.tryParse(balanceText.trim()) ?? 0;
                      if (selectedUserId == null || cardIdText.trim().isEmpty || amount < 0) {
                        return;
                      }
                      try {
                        final callable = _fx.httpsCallable('registerCardToUser');
                        await callable.call({
                          'cardId': cardIdText.trim(),
                          'userId': selectedUserId,
                          'initialBalanceRwf': amount,
                          'active': true,
                        });
                        if (!ctx.mounted) return;
                        FocusManager.instance.primaryFocus?.unfocus();
                        Navigator.pop(ctx);
                        _showSnack('Card registered to user successfully.');
                      } catch (e) {
                        _showSnack('Card registration failed: ${_friendlyError(e)}');
                      }
                    },
                    icon: const Icon(Icons.credit_card_rounded),
                    label: const Text('Register Card'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_isSuperAdmin) {
      return _buildSuperAdminConsole();
    }
    if (_enterConsole && _agencyId != null && _error == null) {
      return _buildAgencyConsole();
    }
    return _buildAgencyAccessHub();
  }

  Widget _buildSuperAdminConsole() {
    final totals = Map<String, dynamic>.from(_systemCounts?['totals'] as Map? ?? {});
    final active = Map<String, dynamic>.from(_systemCounts?['active'] as Map? ?? {});

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Super Admin Console'),
          actions: [
            IconButton(
              tooltip: 'Refresh counts',
              onPressed: _refreshSystemCounts,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Approvals'),
              Tab(text: 'Reset Queue'),
              Tab(text: 'Analytics'),
              Tab(text: 'Controls'),
              Tab(text: 'Exports'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _fs
                  .collection('agency_applications')
                  .orderBy('submittedAt', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs;
                if (docs.isEmpty) return const Center(child: Text('No applications yet.'));
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final m = d.data();
                    final contact = Map<String, dynamic>.from(m['contact'] as Map? ?? {});
                    final status = '${m['status'] ?? ''}';
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: ListTile(
                        isThreeLine: true,
                        title: Text('${m['agencyName'] ?? 'Agency'}'),
                        subtitle: Text(
                          '${contact['fullName'] ?? ''} - ${m['ownerEmail'] ?? ''}\n'
                          'Fleet: ${m['fleetSize'] ?? 0} - Status: $status',
                        ),
                        trailing: status == 'pending' || status == 'under_review'
                            ? FilledButton(
                                onPressed: () => _approveApplication(d.id),
                                child: const Text('Approve'),
                              )
                            : null,
                      ),
                    );
                  },
                );
              },
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _fs
                  .collection('agency_password_reset_requests')
                  .orderBy('createdAt', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs;
                if (docs.isEmpty) return const Center(child: Text('No reset requests.'));
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final m = d.data();
                    final status = '${m['status'] ?? ''}';
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: ListTile(
                        title: Text('Agency: ${m['agencyId'] ?? ''}'),
                        subtitle: Text(
                          'Requester: ${m['requesterEmail'] ?? m['requesterUid'] ?? ''}\nStatus: $status',
                        ),
                        isThreeLine: true,
                        trailing: status == 'pending'
                            ? Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: () => _resolveResetRequest(d.id, 'rejected'),
                                    child: const Text('Reject'),
                                  ),
                                  FilledButton(
                                    onPressed: () => _resolveResetRequest(d.id, 'resolved'),
                                    child: const Text('Resolve'),
                                  ),
                                ],
                              )
                            : Chip(label: Text(status)),
                      ),
                    );
                  },
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _countsLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        if (_softNotice != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C2D12).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              _softNotice!,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: _statCard(
                                'Users',
                                '${totals['users'] ?? 0}',
                                'Active: ${active['users'] ?? 0}',
                                Colors.blue,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statCard(
                                'Pages',
                                '${totals['pages'] ?? 0}',
                                'Active: ${active['pages'] ?? 0}',
                                Colors.purple,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statCard(
                                'Agencies',
                                '${totals['agencies'] ?? 0}',
                                'Active: ${active['agencies'] ?? 0}',
                                Colors.teal,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'System health snapshot refreshes on demand.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _openRouteForm(),
                      icon: const Icon(Icons.alt_route_rounded),
                      label: const Text('Create Master Direction'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Activate / Deactivate Entities',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _superEntityType,
                    decoration: const InputDecoration(labelText: 'Entity type'),
                    items: const [
                      DropdownMenuItem(value: 'user', child: Text('User')),
                      DropdownMenuItem(value: 'page', child: Text('Page')),
                      DropdownMenuItem(value: 'agency', child: Text('Agency')),
                    ],
                    onChanged: (v) => setState(() => _superEntityType = v ?? 'user'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _superEntityIdCtrl,
                    decoration: const InputDecoration(labelText: 'Entity ID'),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: _superEntityActive,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_superEntityActive ? 'Activate' : 'Deactivate'),
                    onChanged: (v) => setState(() => _superEntityActive = v),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final id = _superEntityIdCtrl.text.trim();
                        if (id.isEmpty) return;
                        _setEntityActiveControl(
                          entityType: _superEntityType,
                          entityId: id,
                          active: _superEntityActive,
                        );
                      },
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'Export Tools',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _superExportType,
                          decoration: const InputDecoration(labelText: 'Entity'),
                          items: const [
                            DropdownMenuItem(value: 'user', child: Text('User')),
                            DropdownMenuItem(value: 'page', child: Text('Page')),
                            DropdownMenuItem(value: 'agency', child: Text('Agency')),
                          ],
                          onChanged: (v) => setState(() => _superExportType = v ?? 'user'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _superExportFormat,
                          decoration: const InputDecoration(labelText: 'Format'),
                          items: const [
                            DropdownMenuItem(value: 'json', child: Text('JSON')),
                            DropdownMenuItem(value: 'csv', child: Text('CSV')),
                          ],
                          onChanged: (v) => setState(() => _superExportFormat = v ?? 'json'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _superExportIdCtrl,
                    decoration: const InputDecoration(labelText: 'Entity ID'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final id = _superExportIdCtrl.text.trim();
                        if (id.isEmpty) return;
                        _exportEntity(
                          entityType: _superExportType,
                          entityId: id,
                          format: _superExportFormat,
                        );
                      },
                      child: const Text('Export Entity'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _superUserACtrl,
                    decoration: const InputDecoration(labelText: 'Chat user A ID'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _superUserBCtrl,
                    decoration: const InputDecoration(labelText: 'Chat user B ID'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        final a = _superUserACtrl.text.trim();
                        final b = _superUserBCtrl.text.trim();
                        if (a.isEmpty || b.isEmpty) return;
                        _exportChat(userA: a, userB: b);
                      },
                      child: const Text('Export Chat Pair'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _exportResult.isEmpty
                              ? 'Export output will appear here.'
                              : _exportResult,
                          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String title, String value, String subtitle, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.08)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildAgencyAccessHub() {
    return Scaffold(
      appBar: AppBar(title: const Text('Agency Console')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 4),
            const Text(
              'Choose an agency mode',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _error ??
                  (_agencyId == null
                      ? 'No agency access yet. You can explore demo or register a real agency.'
                      : 'You have agency access. Open console or switch workflow.'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _submitAgencyApplication,
                icon: const Icon(Icons.approval_outlined),
                label: const Text('Register Real Agency'),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _fs.collection('agencies').where('active', isEqualTo: true).limit(50).snapshots(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(child: Text('No agencies listed yet.'));
                  }
                  return ListView.builder(
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final m = docs[i].data();
                      final name = '${m['name'] ?? 'Agency'}';
                      final code = '${m['code'] ?? ''}';
                      final isDemo = docs[i].id == 'demo_transport_ltd';
                      final belongs = _belongsToAgencyDoc(docs[i].id, m);
                      final canOpen = isDemo || belongs;
                      final subtitleText = isDemo
                          ? 'Demo agency - password: demopassword'
                          : (belongs
                              ? 'Registered agency - You: ${_shortAdminTag()}'
                              : 'Registered agency');
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text((code.isNotEmpty ? code : name.substring(0, 1)).toUpperCase()),
                          ),
                          title: Text(name),
                          subtitle: Text(subtitleText),
                          trailing: FilledButton(
                            onPressed: canOpen
                                ? () => _openAgencyByPassword(
                                      agencyId: docs[i].id,
                                      isDemo: isDemo,
                                    )
                                : null,
                            child: const Text('Open'),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgencyConsole() {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAdmin ? 'Agency Admin Console' : 'Agency Staff Console'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => setState(() => _enterConsole = false),
        ),
        actions: [
          if (_isAdmin)
            IconButton(
              tooltip: 'Set agency password',
              onPressed: _setAgencyPassword,
              icon: const Icon(Icons.lock_reset_rounded),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: _tabs.map((t) => Tab(text: t)).toList(),
        ),
      ),
      floatingActionButton: _tabController.index == 0 && _isAdmin
          ? null
          : _tabController.index == 1 && _isAdmin
              ? FloatingActionButton.extended(
                  onPressed: () => _openBusForm(),
                  label: const Text('Add Bus'),
                  icon: const Icon(Icons.directions_bus_rounded),
                )
          : _tabController.index == 2
              ? FloatingActionButton.extended(
                  onPressed: _topUpCard,
                  label: const Text('Top Up'),
                  icon: const Icon(Icons.account_balance_wallet_rounded),
                )
              : null,
      body: TabBarView(
        controller: _tabController,
        children: [
          _RoutesTab(
            agencyId: _agencyId!,
            canEdit: false,
            onEdit: _openRouteForm,
          ),
          _FleetTab(
            agencyId: _agencyId!,
            canAssign: _isAdmin,
            onAssign: _assignRouteToBus,
            onEditBus: _isAdmin ? _openBusForm : null,
          ),
          _TopUpTab(
            onTopUp: _topUpCard,
            onRegisterCard: _registerCardToUser,
            role: _role ?? '',
            agencyId: _agencyId!,
          ),
          _ActivityTab(agencyId: _agencyId!),
          _BookingsTab(agencyId: _agencyId!),
        ],
      ),
    );
  }
}

class _RoutesTab extends StatelessWidget {
  const _RoutesTab({
    required this.agencyId,
    required this.canEdit,
    required this.onEdit,
  });

  final String agencyId;
  final bool canEdit;
  final Future<void> Function({String? routeId, Map<String, dynamic>? existing}) onEdit;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('routes')
          .where('global', isEqualTo: true)
          .where('active', isEqualTo: true)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No routes yet.'));
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i];
            final m = d.data();
            return ListTile(
              title: Text('${m['origin']} -> ${m['destination']}'),
              subtitle: Text('RWF ${m['fareRwf'] ?? 0}'),
              trailing: canEdit
                  ? IconButton(
                      icon: const Icon(Icons.edit_rounded),
                      onPressed: () => onEdit(routeId: d.id, existing: m),
                    )
                  : null,
            );
          },
        );
      },
    );
  }
}

class _FleetTab extends StatelessWidget {
  const _FleetTab({
    required this.agencyId,
    required this.canAssign,
    required this.onAssign,
    this.onEditBus,
  });

  final String agencyId;
  final bool canAssign;
  final Future<void> Function(String busId, String routeId) onAssign;
  final Future<void> Function({String? busId, Map<String, dynamic>? existing})? onEditBus;

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: fs.collection('buses').where('agencyId', isEqualTo: agencyId).snapshots(),
      builder: (context, busSnap) {
        if (!busSnap.hasData) return const Center(child: CircularProgressIndicator());
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: fs
              .collection('routes')
              .where('global', isEqualTo: true)
              .where('active', isEqualTo: true)
              .snapshots(),
          builder: (context, routeSnap) {
            if (!routeSnap.hasData) return const Center(child: CircularProgressIndicator());
            final routes = routeSnap.data!.docs;
            final routeLabels = {
              for (final r in routes)
                r.id: '${r.data()['origin'] ?? ''} -> ${r.data()['destination'] ?? ''}',
            };
            final buses = busSnap.data!.docs;
            if (buses.isEmpty) return const Center(child: Text('No buses yet.'));
            return ListView.builder(
              itemCount: buses.length,
              itemBuilder: (context, i) {
                final b = buses[i];
                final m = b.data();
                final currentRoute = '${m['routeId'] ?? ''}';
                final currentRouteLabel = currentRoute.isEmpty
                    ? 'None'
                    : (routeLabels[currentRoute] ?? 'Unknown route');
                return ListTile(
                  title: Text('${m['agencyName'] ?? 'Bus'} - ${m['plateNumber'] ?? ''}'),
                  subtitle: Text(
                    'Current route: $currentRouteLabel',
                  ),
                  trailing: canAssign
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit bus',
                              onPressed: onEditBus == null
                                  ? null
                                  : () => onEditBus!(busId: b.id, existing: m),
                              icon: const Icon(Icons.edit_rounded),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Assign route',
                              onSelected: (rid) => onAssign(b.id, rid),
                              itemBuilder: (context) => routes
                                  .map(
                                    (r) => PopupMenuItem(
                                      value: r.id,
                                      child: Text('${r['origin']} -> ${r['destination']}'),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        )
                      : null,
                );
              },
            );
          },
        );
      },
    );
  }
}

class _TopUpTab extends StatelessWidget {
  const _TopUpTab({
    required this.onTopUp,
    required this.onRegisterCard,
    required this.role,
    required this.agencyId,
  });
  final Future<void> Function() onTopUp;
  final Future<void> Function() onRegisterCard;
  final String role;
  final String agencyId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onRegisterCard,
                  icon: const Icon(Icons.badge_rounded),
                  label: const Text('Register Card'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onTopUp,
                  icon: const Icon(Icons.account_balance_wallet_rounded),
                  label: const Text('Top Up Card'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Role: $role', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('cards')
                  .where('issuerAgencyId', isEqualTo: agencyId)
                  .limit(120)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Text(
                      'Could not load cards.\n${snap.error}',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = [...snap.data!.docs]
                  ..sort((a, b) {
                    final at = (a.data()['updatedAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                    final bt = (b.data()['updatedAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                    return bt.compareTo(at);
                  });
                if (docs.isEmpty) {
                  return const Center(child: Text('No cards registered by this agency yet.'));
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i].data();
                    final active = d['active'] == true;
                    return ListTile(
                      leading: Icon(
                        Icons.credit_card_rounded,
                        color: active ? const Color(0xFF22C55E) : const Color(0xFF9CA3AF),
                      ),
                      title: Text('Card ${docs[i].id}'),
                      subtitle: Text(
                        'Owner: ${d['ownerName'] ?? d['userId'] ?? ''} - Balance: RWF ${d['balanceRwf'] ?? 0}',
                      ),
                      trailing: Chip(
                        label: Text(active ? 'Active' : 'Inactive'),
                        visualDensity: VisualDensity.compact,
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

class _ActivityTab extends StatelessWidget {
  const _ActivityTab({required this.agencyId});
  final String agencyId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('admin_events')
          .where('agencyId', isEqualTo: agencyId)
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load activity yet.\n${snap.error}',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No recent activity.'));
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i].data();
            return ListTile(
              title: Text('${d['type'] ?? 'Event'}'),
              subtitle: Text('${d['description'] ?? ''}'),
              trailing: Text('${d['actorRole'] ?? ''}'),
            );
          },
        );
      },
    );
  }
}

class _BookingsTab extends StatelessWidget {
  const _BookingsTab({required this.agencyId});
  final String agencyId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .where('agencyId', isEqualTo: agencyId)
          .orderBy('createdAt', descending: true)
          .limit(150)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load bookings yet.\n${snap.error}',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No bookings yet.'));
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final m = docs[i].data();
            final status = '${m['status'] ?? ''}';
            final rider = '${m['bookingUserName'] ?? m['userName'] ?? m['userId'] ?? ''}';
            final cardOwner = '${m['cardOwnerName'] ?? m['cardOwnerUid'] ?? rider}';
            final routeLabel = '${m['routeLabel'] ?? m['routeId'] ?? ''}';
            final busLabel = '${m['plateNumber'] ?? m['busId'] ?? ''}';
            final usedExternalCard = m['usedExternalCard'] == true;
            final color = status == 'paid'
                ? const Color(0xFF22C55E)
                : status == 'booked'
                    ? const Color(0xFF3B82F6)
                    : status == 'expired'
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF9CA3AF);
            return Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: ListTile(
                title: Text('Bus $busLabel - Seat ${m['seatNo'] ?? '-'}'),
                subtitle: Text(
                  'Rider: $rider${usedExternalCard ? ' (other card)' : ''}\n'
                  'Card owner: $cardOwner - Card: ${m['cardId'] ?? ''}\n'
                  'Route: $routeLabel - Fare: RWF ${m['fareRwf'] ?? 0}',
                ),
                isThreeLine: true,
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: color.withValues(alpha: 0.42)),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}


