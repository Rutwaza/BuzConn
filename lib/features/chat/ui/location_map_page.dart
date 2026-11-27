import 'dart:async';
import 'package:businessfinder/core/i18n/tr.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../data/live_location_service.dart';

/// Full-screen map for a location message.
/// Shows the sender's pin (with their photo), your own position as the blue
/// "me" dot, the distance between you, and a Directions button.
class LocationMapPage extends StatefulWidget {
  const LocationMapPage({
    super.key,
    required this.chatId,
    required this.messageId,
    required this.senderName,
    this.senderAvatar,
  });

  final String chatId;
  final String messageId;
  final String senderName;
  final String? senderAvatar;

  @override
  State<LocationMapPage> createState() => _LocationMapPageState();
}

class _LocationMapPageState extends State<LocationMapPage> {
  final _map = MapController();
  StreamSubscription<Position>? _meSub;
  LatLng? _me;
  bool _centeredOnce = false;
  String? _meProblem;

  @override
  void initState() {
    super.initState();
    _startMe();
  }

  Future<void> _startMe() async {
    try {
      final p = await LiveLocationService.currentPosition();
      if (!mounted) return;
      setState(() => _me = LatLng(p.latitude, p.longitude));
      _meSub = LiveLocationService.positionStream().listen((p) {
        if (mounted) setState(() => _me = LatLng(p.latitude, p.longitude));
      }, onError: (_) {});
    } catch (e) {
      if (mounted) setState(() => _meProblem = e.toString());
    }
  }

  @override
  void dispose() {
    _meSub?.cancel();
    super.dispose();
  }

  void _fitBoth(LatLng them) {
    final me = _me;
    if (me == null) {
      _map.move(them, 16);
      return;
    }
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(them, me),
      padding: const EdgeInsets.all(70),
      maxZoom: 17,
    ));
  }

  Future<void> _directions(LatLng to) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${to.latitude},${to.longitude}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(widget.messageId);
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: ref.snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final loc = data?['location'];
        if (loc is! Map) {
          return Scaffold(
            appBar: AppBar(title: Text(tr('Location'))),
            body: Center(
              child: snap.connectionState == ConnectionState.waiting &&
              !snap.hasData
                  ? const CircularProgressIndicator()
                  : Text(tr('This location is no longer available.')),
            ),
          );
        }
        final them = LatLng(
          (loc['lat'] as num).toDouble(),
          (loc['lng'] as num).toDouble(),
        );
        final info = LocationInfo.fromMessage(data!);
        final isMine = data['senderId'] == myUid;

        if (!_centeredOnce) {
          _centeredOnce = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitBoth(them));
        }

        final distance = _me == null
            ? null
            : Geolocator.distanceBetween(
                _me!.latitude, _me!.longitude, them.latitude, them.longitude);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isMine ? 'Your location' : widget.senderName),
                Text(info.statusLine(),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          body: Stack(
            children: [
              FlutterMap(
                mapController: _map,
                options: MapOptions(initialCenter: them, initialZoom: 16),
                children: [
                  TileLayer(
                    urlTemplate: AppConstants.mapTileUrl,
                    userAgentPackageName: AppConstants.mapUserAgent,
                  ),
                  if (loc['accuracy'] is num)
                    CircleLayer(circles: [
                      CircleMarker(
                        point: them,
                        radius: (loc['accuracy'] as num).toDouble(),
                        useRadiusInMeter: true,
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderColor: AppColors.primary.withValues(alpha: 0.4),
                        borderStrokeWidth: 1,
                      ),
                    ]),
                  MarkerLayer(markers: [
                    if (_me != null && !isMine)
                      Marker(point: _me!, width: 26, height: 26, child: const MeDot()),
                    Marker(
                      point: them,
                      width: 56,
                      height: 66,
                      alignment: Alignment.topCenter,
                      child: AvatarPin(
                        imageUrl: widget.senderAvatar,
                        name: widget.senderName,
                        live: info.isLiveNow,
                      ),
                    ),
                  ]),
                ],
              ),
              Positioned(
                right: 14,
                bottom: 150,
                child: Column(children: [
                  FloatingActionButton.small(
                    heroTag: 'them',
                    tooltip: tr('Show both'),
                    onPressed: () => _fitBoth(them),
                    child: const Icon(Icons.zoom_out_map_rounded),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton.small(
                    heroTag: 'me',
                    tooltip: tr('Where am I'),
                    onPressed: _me == null ? null : () => _map.move(_me!, 17),
                    child: const Icon(Icons.my_location_rounded),
                  ),
                ]),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: SafeArea(
                  child: Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                distance != null && !isMine
                                    ? '${formatDistance(distance)} away'
                                    : info.isLive
                                        ? 'Live location'
                                        : 'Shared location',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _meProblem != null && !isMine
                                    ? _meProblem!
                                    : info.updatedLine(),
                                style: const TextStyle(color: AppColors.grey),
                              ),
                            ],
                          ),
                        ),
                        if (isMine && info.isLiveNow)
                          TextButton(
                            onPressed: () {
                              LiveLocationService.instance.stop(widget.messageId);
                            },
                            style: TextButton.styleFrom(
                                foregroundColor: AppColors.error),
                            child: Text(tr('Stop')),
                          )
                        else if (!isMine)
                          FilledButton.icon(
                            onPressed: () => _directions(them),
                            icon: const Icon(Icons.directions_rounded),
                            label: Text(tr('Directions')),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What a location message says about itself (live or not, last update).
class LocationInfo {
  LocationInfo({
    required this.isLive,
    required this.until,
    required this.ended,
    required this.updatedAt,
  });

  factory LocationInfo.fromMessage(Map<String, dynamic> data) {
    final loc = data['location'];
    final updated = loc is Map ? loc['updatedAt'] : null;
    return LocationInfo(
      isLive: data['live'] == true,
      until: (data['liveUntil'] as Timestamp?)?.toDate(),
      ended: data['liveEnded'] == true,
      updatedAt: updated is Timestamp
          ? updated.toDate()
          : (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  final bool isLive;
  final DateTime? until;
  final bool ended;
  final DateTime? updatedAt;

  bool get isLiveNow =>
      isLive && !ended && until != null && until!.isAfter(DateTime.now());

  String statusLine() {
    if (!isLive) return 'Location';
    if (isLiveNow) return 'Live until ${_hm(until!)}';
    return 'Live location ended';
  }

  String updatedLine() {
    final at = updatedAt;
    if (at == null) return '';
    final ago = DateTime.now().difference(at);
    if (ago.inSeconds < 60) return 'Updated just now';
    if (ago.inMinutes < 60) return 'Updated ${ago.inMinutes} min ago';
    if (ago.inHours < 24) return 'Updated ${ago.inHours} h ago';
    return 'Sent ${at.day}/${at.month}/${at.year}';
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String formatDistance(double metres) {
  if (metres < 1000) return '${metres.round()} m';
  return '${(metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0)} km';
}

/// The blue "me" dot.
class MeDot extends StatelessWidget {
  const MeDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.info,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: AppColors.info.withValues(alpha: 0.35),
            blurRadius: 8,
            spreadRadius: 4,
          ),
        ],
      ),
    );
  }
}

/// A map pin with the person's photo (or initial). Teal ring when live.
class AvatarPin extends StatelessWidget {
  const AvatarPin({
    super.key,
    required this.name,
    this.imageUrl,
    this.live = false,
    this.size = 44,
  });

  final String name;
  final String? imageUrl;
  final bool live;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ring = live ? AppColors.secondary : AppColors.primary;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final url = imageUrl;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: ring,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
          ),
          child: CircleAvatar(
            backgroundColor: AppColors.mist,
            backgroundImage:
                url != null && url.startsWith('http') ? NetworkImage(url) : null,
            child: url != null && url.startsWith('http')
                ? null
                : Text(initial,
                    style: const TextStyle(
                        color: AppColors.primary, fontWeight: FontWeight.w800)),
          ),
        ),
        CustomPaint(size: const Size(14, 9), painter: _PinTip(ring)),
      ],
    );
  }
}

class _PinTip extends CustomPainter {
  _PinTip(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PinTip old) => old.color != color;
}
