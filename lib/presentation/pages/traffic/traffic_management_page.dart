import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

import '../../../core/theme/colors.dart';

class TrafficManagementPage extends StatefulWidget {
  const TrafficManagementPage({super.key});

  @override
  State<TrafficManagementPage> createState() => _TrafficManagementPageState();
}

class _TrafficManagementPageState extends State<TrafficManagementPage> {
  static const LatLng _kigaliCenter = LatLng(-1.9441, 30.0619);
  final MapController _mapController = MapController();
  LatLng _mapCenter = _kigaliCenter;
  bool _isLocating = true;
  bool _useDarkMap = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _resolveUserLocation();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _resolveUserLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setCenter(_kigaliCenter);
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setCenter(_kigaliCenter);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
      _setCenter(LatLng(position.latitude, position.longitude));
    } catch (_) {
      _setCenter(_kigaliCenter);
    }
  }

  void _setCenter(LatLng center) {
    setState(() {
      _mapCenter = center;
      _isLocating = false;
    });
    _mapController.move(_mapCenter, 12);
  }

  Future<void> _searchAndFocus() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    try {
      final results = await locationFromAddress(query);
      if (results.isEmpty) return;
      final first = results.first;
      _setCenter(LatLng(first.latitude, first.longitude));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location not found')),
        );
      }
    }
  }

  List<Marker> _buildMarkers(List<QueryDocumentSnapshot> docs) {
    return docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final lat = data['lat'];
      final lng = data['lng'];
      if (lat == null || lng == null) {
        return null;
      }
      return Marker(
        point: LatLng(lat.toDouble(), lng.toDouble()),
        width: 36,
        height: 36,
        child: const Icon(Icons.location_on, color: AppColors.primary, size: 32),
      );
    }).whereType<Marker>().toList();
  }

  @override
  Widget build(BuildContext context) {
    final tileUrl = _useDarkMap
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
        : 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traffic Management'),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _useDarkMap = !_useDarkMap;
              });
            },
            icon: Icon(_useDarkMap ? Icons.light_mode : Icons.dark_mode),
            tooltip: _useDarkMap ? 'Light map' : 'Dark map',
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('traffic_devices')
            .where('active', isEqualTo: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final docs = snapshot.data?.docs ?? [];
          final markers = _buildMarkers(docs);

          return Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _mapCenter,
                  initialZoom: 12,
                ),
                children: [
                  TileLayer(
                    urlTemplate: tileUrl,
                    subdomains: const ['a', 'b', 'c', 'd'],
                    userAgentPackageName: 'businessfinder',
                  ),
                  MarkerLayer(markers: markers),
                ],
              ),
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: const InputDecoration(
                            hintText: 'Search location',
                            border: InputBorder.none,
                          ),
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _searchAndFocus(),
                        ),
                      ),
                      IconButton(
                        onPressed: _searchAndFocus,
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        tooltip: 'Go',
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                bottom: 64,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('Live devices: ${markers.length}'),
                    ],
                  ),
                ),
              ),
              if (_isLocating)
                const Positioned(
                  top: 16,
                  left: 16,
                  child: SizedBox(
                    height: 28,
                    width: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Positioned(
                left: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '(c) OpenStreetMap contributors (CARTO)',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
