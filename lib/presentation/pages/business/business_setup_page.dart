import 'package:businessfinder/core/widgets/emoji_picker.dart';
import 'package:businessfinder/core/services/media_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
import 'dart:io';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../features/billing/billing_service.dart';
import '../../../features/billing/upgrade_sheets.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/opening_hours.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/services/r2_storage_service.dart';

class BusinessSetupPage extends ConsumerStatefulWidget {
  const BusinessSetupPage({super.key, this.editBusinessId});

  final String? editBusinessId;

  @override
  ConsumerState<BusinessSetupPage> createState() => _BusinessSetupPageState();
}

class _BusinessSetupPageState extends ConsumerState<BusinessSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _businessNameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _addressController = TextEditingController();
  final _googleMapsLinkController = TextEditingController();
  final _phoneController = TextEditingController();
  final _momoCodeController = TextEditingController();
  final _momoNameController = TextEditingController();
  final _emailController = TextEditingController();
  // Opening hours: null = not changed, {} = remove, else the new hours.
  Map<String, String>? _hours;
  Object? _savedHours;

  String _selectedCategory = 'Other';
  bool _isLoading = false;
  File? _selectedImage;
  Uint8List? _selectedImageBytes;
  static const LatLng _defaultMapCenter = LatLng(-1.9441, 30.0619);
  LatLng? _selectedLocation;
  bool _isResolvingLocation = false;
  String? _existingImageUrl;

  bool get _isEditMode =>
      widget.editBusinessId != null && widget.editBusinessId!.isNotEmpty;

  bool get _supportsNativeGoogleMap =>
      !AppConstants.pauseGoogleMaps &&
      (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  final List<String> _categories = [
    'Restaurant',
    'Retail',
    'Healthcare',
    'Education',
    'Technology',
    'Construction',
    'Automotive',
    'Beauty & Spa',
    'Fitness',
    'Consulting',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
    _loadBusinessForEdit();
  }

  Future<void> _loadCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _emailController.text = user.email ?? '';
      if (_phoneController.text.trim().isEmpty) {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final data = doc.data() ?? {};
        final phone = (data['phone'] ?? data['phoneNumber'])?.toString();
        if (phone != null && phone.trim().isNotEmpty) {
          _phoneController.text = phone.trim();
        }
      }
    }
  }

  Future<void> _loadBusinessForEdit() async {
    if (!_isEditMode) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('businesses')
          .doc(widget.editBusinessId)
          .get();
      final data = snap.data();
      if (!mounted || data == null) return;
      setState(() {
        _businessNameController.text = (data['name'] ?? '').toString();
        _descriptionController.text = (data['description'] ?? '').toString();
        final address = (data['address'] ?? data['location'] ?? '').toString();
        _addressController.text = address;
        _googleMapsLinkController.text =
            (data['googleMapsLink'] ?? '').toString();
        _phoneController.text = (data['phone'] ?? '').toString();
        _momoCodeController.text = (data['momoCode'] ?? '').toString();
        _momoNameController.text = (data['momoName'] ?? '').toString();
        _emailController.text = (data['email'] ?? '').toString();
        _savedHours = data['hours'];
        final category = (data['category'] ?? 'Other').toString();
        _selectedCategory = _categories.contains(category) ? category : 'Other';
        _existingImageUrl = (data['imageUrl'] ?? '').toString();
        final lat = (data['lat'] ?? data['latitude']) as num?;
        final lng = (data['lng'] ?? data['longitude']) as num?;
        if (lat != null && lng != null) {
          _selectedLocation = LatLng(lat.toDouble(), lng.toDouble());
        }
      });
    } catch (_) {
      // Keep setup usable even if edit prefill fails.
    }
  }

  Future<void> _saveBusiness() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          if (_selectedLocation == null &&
              _addressController.text.trim().isNotEmpty) {
            await _pinLocationFromAddress(showFeedback: false);
          }

          final address = _addressController.text.trim();
          final mapsLink = _googleMapsLinkController.text.trim().isNotEmpty
              ? _googleMapsLinkController.text.trim()
              : _selectedLocation != null
                  ? _buildMapsLinkFromCoordinates(_selectedLocation!)
                  : address.isNotEmpty
                      ? _buildMapsLinkFromAddress(address)
                      : '';

          final businessData = <String, dynamic>{
            'name': _businessNameController.text.trim(),
            'description': _descriptionController.text.trim(),
            'category': _selectedCategory,
            'address': address,
            'location': address,
            'phone': _phoneController.text.trim(),
            'momoCode': _momoCodeController.text.trim(),
            'momoName': _momoNameController.text.trim(),
            'email': _emailController.text.trim(),
            if (_hours != null)
              'hours': _hours!.isEmpty
                  ? (_isEditMode ? FieldValue.delete() : null)
                  : _hours,
            if (_selectedLocation != null) ...{
              'latitude': _selectedLocation!.latitude,
              'longitude': _selectedLocation!.longitude,
              'lat': _selectedLocation!.latitude,
              'lng': _selectedLocation!.longitude,
            },
            'updatedAt': FieldValue.serverTimestamp(),
          };
          late final DocumentReference<Map<String, dynamic>> businessRef;
          if (_isEditMode) {
            businessRef = FirebaseFirestore.instance
                .collection('businesses')
                .doc(widget.editBusinessId);
            await businessRef.update(businessData);
          } else {
            // Made by the server: the first page is free, more pages need
            // a paid place (functions/pages.js createPage).
            final r = await BillingService.instance.createPage({
              ...(Map<String, Object?>.from(businessData)
                ..remove('updatedAt')
                ..removeWhere((k, v) => v == null)),
              'googleMapsLink': mapsLink,
            });
            if (r['needSlot'] == true) {
              setState(() => _isLoading = false);
              if (!mounted) return;
              final bought = await showPageSlotsSheet(context);
              if (bought && mounted) await _saveBusiness();
              return;
            }
            businessRef = FirebaseFirestore.instance
                .collection('businesses')
                .doc(r['id'].toString());
          }

          // Upload image if selected
          String? imageUrl;
          if (_selectedImage != null) {
            imageUrl = await _uploadImage(_selectedImage!, businessRef.id);
          }

          // Update business document with image URL
          await businessRef.update({
            'googleMapsLink': mapsLink,
            if (imageUrl != null) 'imageUrl': imageUrl,
          });

          setState(() {
            _isLoading = false;
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(tr('Page saved successfully!')),
                backgroundColor: Colors.green,
              ),
            );

            // Navigate to dashboard
            context.go(AppRoutes.dashboard);
          }
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(tr('Failed to create page. Please try again.'))),
          );
        }
      }
    }
  }

  Widget _hoursTile() {
    final current = _hours ?? _savedHours;
    final h = (current is Map && current.isNotEmpty) ? current : null;
    return Material(
      color: AppColors.primary.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: const Icon(Icons.schedule_rounded, color: AppColors.primary),
        title: Text(tr('Opening hours')),
        subtitle: h == null
            ? Text(tr('Optional: show "Open now" on your page'))
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OpenStatusChip(hours: h),
                ),
              ),
        trailing: TextButton(
          onPressed: () async {
            final r = await showOpeningHoursEditor(context, current);
            if (r != null) setState(() => _hours = r);
          },
          child: Text(h == null ? tr('Add') : tr('Edit')),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _businessNameController.dispose();
    _descriptionController.dispose();
    _addressController.dispose();
    _googleMapsLinkController.dispose();
    _phoneController.dispose();
    _momoCodeController.dispose();
    _momoNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final pickedFile =
          await MediaPicker.pickImage(source: ImageSource.gallery);

      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        setState(() {
          _selectedImage = File(pickedFile.path);
          _selectedImageBytes = bytes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image picker failed: $e')),
        );
      }
    }
  }

  Future<String?> _uploadImage(File imageFile, String businessId) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final path =
          '$businessId/logo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      return await R2StorageService.instance.uploadImage(
        bucket: 'profile-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading image: $e');
      return null;
    }
  }

  String _buildMapsLinkFromAddress(String address) {
    final encoded = Uri.encodeComponent(address.trim());
    return 'https://www.google.com/maps/search/?api=1&query=$encoded';
  }

  String _buildMapsLinkFromCoordinates(LatLng point) {
    final lat = point.latitude.toStringAsFixed(6);
    final lng = point.longitude.toStringAsFixed(6);
    return 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
  }

  LatLng? _extractPointFromMapsLink(String link) {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      final q = uri.queryParameters['q'] ?? uri.queryParameters['query'];
      if (q != null) {
        final parts = q.split(',');
        if (parts.length >= 2) {
          final lat = double.tryParse(parts[0].trim());
          final lng = double.tryParse(parts[1].trim());
          if (lat != null && lng != null) {
            return LatLng(lat, lng);
          }
        }
      }
    }

    final atMatch =
        RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)').firstMatch(trimmed);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1) ?? '');
      final lng = double.tryParse(atMatch.group(2) ?? '');
      if (lat != null && lng != null) {
        return LatLng(lat, lng);
      }
    }

    return null;
  }

  String _formatPlacemark(geo.Placemark placemark) {
    return [
      placemark.street,
      placemark.subLocality,
      placemark.locality,
      placemark.country,
    ]
        .where((part) => part != null && part.trim().isNotEmpty)
        .map((part) => part!.trim())
        .join(', ');
  }

  void _setPinnedLocation(
    LatLng point, {
    String? prefillAddress,
    String? successMessage,
  }) {
    setState(() {
      _selectedLocation = point;
    });
    if (prefillAddress != null && prefillAddress.trim().isNotEmpty) {
      _addressController.text = prefillAddress.trim();
    }
    _googleMapsLinkController.text = _buildMapsLinkFromCoordinates(point);
    if (successMessage != null && mounted) {
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage)),
      );
    }
  }

  Future<void> _pinLocationFromAddress({bool showFeedback = true}) async {
    final address = _addressController.text.trim();
    if (address.isEmpty) {
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Add your address first'))),
        );
      }
      return;
    }

    setState(() {
      _isResolvingLocation = true;
    });

    try {
      final results = await geo.locationFromAddress(address);
      if (results.isEmpty) {
        throw Exception('Could not find that address yet.');
      }
      final first = results.first;
      _setPinnedLocation(
        LatLng(first.latitude, first.longitude),
        successMessage: showFeedback ? 'Location pinned from address' : null,
      );
    } catch (_) {
      if (mounted && showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Could not find that address yet. Try a fuller address or use current location.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResolvingLocation = false;
        });
      }
    }
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _isResolvingLocation = true;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are turned off.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission was not granted.');
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      String? resolvedAddress;
      try {
        final placemarks = await geo.placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          resolvedAddress = _formatPlacemark(placemarks.first);
        }
      } catch (_) {
        // Keep the coordinates even if reverse geocoding fails.
      }

      _setPinnedLocation(
        LatLng(position.latitude, position.longitude),
        prefillAddress: resolvedAddress,
        successMessage: 'Current location added',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResolvingLocation = false;
        });
      }
    }
  }

  Future<void> _pasteMapsLink() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted) return;

    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Clipboard is empty'))),
      );
      return;
    }

    _googleMapsLinkController.text = text;
    final point = _extractPointFromMapsLink(text);
    if (point != null) {
      setState(() {
        _selectedLocation = point;
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            point != null
                ? 'Map link pasted and pin detected'
                : 'Map link pasted',
          ),
        ),
      );
    }
  }

  Widget _buildLocationPreviewMap() {
    final point = _selectedLocation;

    if (_supportsNativeGoogleMap) {
      return gmaps.GoogleMap(
        initialCameraPosition: gmaps.CameraPosition(
          target: gmaps.LatLng(
            point?.latitude ?? _defaultMapCenter.latitude,
            point?.longitude ?? _defaultMapCenter.longitude,
          ),
          zoom: point == null ? 10.5 : 15,
        ),
        onTap: (tappedPoint) {
          _setPinnedLocation(
            LatLng(tappedPoint.latitude, tappedPoint.longitude),
          );
        },
        markers: point == null
            ? const <gmaps.Marker>{}
            : {
                gmaps.Marker(
                  markerId: const gmaps.MarkerId('business-pin'),
                  position: gmaps.LatLng(point.latitude, point.longitude),
                  draggable: true,
                  onDragEnd: (draggedPoint) {
                    _setPinnedLocation(
                      LatLng(draggedPoint.latitude, draggedPoint.longitude),
                    );
                  },
                ),
              },
        mapType: gmaps.MapType.normal,
        zoomControlsEnabled: false,
        myLocationButtonEnabled: false,
        mapToolbarEnabled: false,
        compassEnabled: true,
        trafficEnabled: false,
        indoorViewEnabled: false,
      );
    }

    return FlutterMap(
      options: MapOptions(
        initialCenter: point ?? _defaultMapCenter,
        initialZoom: point == null ? 10.5 : 15,
        onTap: (_, tappedPoint) {
          _setPinnedLocation(tappedPoint);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: AppConstants.mapUserAgent,
        ),
        if (point != null)
          MarkerLayer(
            markers: [
              Marker(
                point: point,
                width: 70,
                height: 70,
                child: const Icon(
                  Icons.location_on_rounded,
                  color: AppColors.primary,
                  size: 42,
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Page' : 'Set Up Your Page'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionCard(
                child: Row(
                  children: [
                    Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        CircleAvatar(
                          radius: 38,
                          backgroundColor:
                              AppColors.primary.withValues(alpha: 0.2),
                          backgroundImage: _selectedImageBytes != null
                              ? MemoryImage(_selectedImageBytes!)
                                  as ImageProvider<Object>?
                              : (_existingImageUrl != null &&
                                      _existingImageUrl!.isNotEmpty)
                                  ? NetworkImage(_existingImageUrl!)
                                      as ImageProvider<Object>?
                                  : null,
                          foregroundImage: null,
                          child: (_selectedImageBytes == null &&
                                  (_existingImageUrl == null ||
                                      _existingImageUrl!.isEmpty))
                              ? const Icon(
                                  Icons.person,
                                  size: 36,
                                  color: Colors.white70,
                                )
                              : null,
                        ),
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: AppColors.primary,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.edit,
                                size: 14, color: Colors.white),
                            onPressed: _pickImage,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('Build your Duhuze page'),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            tr('Show your work, connect with fans, and share updates.'),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              _sectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Page basics'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _businessNameController,
                      label: tr('Page Name'),
                      hintText: tr('Your creator name or brand'),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your page name';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('Category'),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedCategory,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      items: _categories.map((category) {
                        return DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedCategory = value!;
                        });
                      },
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please select a category';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _descriptionController,
                      suffixIcon:
                          EmojiButton(controller: _descriptionController),
                      label: tr('Bio'),
                      hintText: tr('Describe your work and style...'),
                      maxLines: 3,
                      maxLength: 500,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a short bio';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),

              _sectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Location'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _addressController,
                      label: tr('Address'),
                      hintText: tr('City, street, building, or venue'),
                      maxLines: 2,
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isResolvingLocation
                              ? null
                              : _pinLocationFromAddress,
                          icon: const Icon(Icons.search_rounded),
                          label: Text(tr('Pin from address')),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _isResolvingLocation ? null : _useCurrentLocation,
                          icon: const Icon(Icons.my_location_rounded),
                          label: Text(tr('Use current location')),
                        ),
                        OutlinedButton.icon(
                          onPressed: _pasteMapsLink,
                          icon: const Icon(Icons.paste_rounded),
                          label: Text(tr('Paste map link')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _googleMapsLinkController,
                      label: tr('Google Maps Link (optional)'),
                      hintText:
                          tr('Auto-filled after pinning, or paste your link'),
                      keyboardType: TextInputType.url,
                      onChanged: (value) {
                        final point = _extractPointFromMapsLink(value);
                        if (point != null) {
                          setState(() {
                            _selectedLocation = point;
                          });
                        }
                      },
                      validator: (value) {
                        final link = value?.trim() ?? '';
                        final address = _addressController.text.trim();
                        if (address.isEmpty &&
                            link.isEmpty &&
                            _selectedLocation == null) {
                          return 'Add an address or pin a location';
                        }
                        if (link.isNotEmpty) {
                          final uri = Uri.tryParse(link);
                          if (uri == null || !uri.hasScheme) {
                            return 'Please enter a valid map link';
                          }
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white.withValues(alpha: 0.04)
                            : Colors.black.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.black12,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.place_rounded,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _selectedLocation == null
                                      ? 'No exact point pinned yet'
                                      : 'Pinned at ${_selectedLocation!.latitude.toStringAsFixed(5)}, ${_selectedLocation!.longitude.toStringAsFixed(5)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_isResolvingLocation) ...[
                            const SizedBox(height: 10),
                            const LinearProgressIndicator(minHeight: 3),
                          ],
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: SizedBox(
                              height: 180,
                              child: _buildLocationPreviewMap(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _selectedLocation == null
                                ? 'Use your current location, search by address, or tap the map to place the page pin exactly where the business is.'
                                : 'This exact pin will be shown on the public business profile. You can tap or drag it to fine-tune the spot.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.grey),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('Tip: exact coordinates work better than just pasting an external link.'),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.grey),
                    ),
                  ],
                ),
              ),

              _sectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Contact'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _phoneController,
                      label: tr('Contact Phone'),
                      hintText: '+1 (555) 123-4567',
                      keyboardType: TextInputType.phone,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your phone number';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _momoCodeController,
                      label: tr('MoMo Pay merchant code (optional)'),
                      hintText: 'e.g. 123456',
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        final v = (value ?? '').trim();
                        if (v.isEmpty) return null;
                        if (!RegExp(r'^\d{4,10}$').hasMatch(v)) {
                          return 'Only the digits of your MoMo Pay code';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _momoNameController,
                      label: tr('Name registered on MoMo Pay'),
                      hintText: tr('The name MTN shows to customers'),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        tr('With a MoMo Pay code your customers can buy from your Shop. Money goes straight to your MoMo; Duhuze never holds it.'),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _hoursTile(),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _emailController,
                      label: tr('Contact Email'),
                      hintText: tr('creator@example.com'),
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                            .hasMatch(value)) {
                          return 'Please enter a valid email address';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),

              _sectionCard(
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tr('Your first page is free. Your page is visible right away; to get the blue ✓ later, use Get verified on the page.'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),

              // Create Page Button
              AppButton(
                text: _isEditMode ? 'Save Changes' : 'Create Page',
                onPressed: _saveBusiness,
                isLoading: _isLoading,
              ),

              const SizedBox(height: 16),

              // Skip for now
              Center(
                child: OutlinedButton(
                  onPressed: () {
                    context.go(AppRoutes.dashboard);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 12),
                    side: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.25),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: Text(tr('Skip for now')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
