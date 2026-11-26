import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/i18n/tr.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/verified_badge.dart';
import '../../../core/widgets/opening_hours.dart';

/// One page shown on the Discover map.
class MapPage {
  const MapPage({
    required this.id,
    required this.name,
    required this.point,
    this.imageUrl,
    this.category = '',
    this.place = '',
    this.verified = false,
    this.mapsLink = '',
    this.hours,
  });

  final String id;
  final String name;
  final LatLng point;
  final String? imageUrl;
  final String category;
  final String place;
  final bool verified;
  final String mapsLink;
  final Object? hours;
}

/// Discover map: page logos as pins, tap one to see a small card,
/// zoom / fit-all buttons, light or dark map to match the app.
class PagesMap extends StatefulWidget {
  const PagesMap({
    super.key,
    required this.pages,
    required this.onOpenPage,
    this.loading = false,
    this.fallbackCenter = const LatLng(-1.9441, 30.0619), // Kigali
  });

  final List<MapPage> pages;
  final void Function(String pageId) onOpenPage;
  final bool loading;
  final LatLng fallbackCenter;

  @override
  State<PagesMap> createState() => PagesMapState();
}

class PagesMapState extends State<PagesMap> {
  final _map = MapController();
  bool _ready = false;
  String? _selectedId;

  MapPage? get _selected {
    for (final p in widget.pages) {
      if (p.id == _selectedId) return p;
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant PagesMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New pins arrived (search changed or locations finished loading).
    if (oldWidget.pages.length != widget.pages.length) {
      if (_selected == null) _selectedId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => fitAll());
    }
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  /// Show every pin.
  void fitAll() {
    if (!_ready || !mounted) return;
    final pts = widget.pages.map((p) => p.point).toList();
    if (pts.isEmpty) {
      _map.move(widget.fallbackCenter, 11.5);
    } else if (pts.length == 1) {
      _map.move(pts.first, 14);
    } else {
      _map.fitCamera(CameraFit.coordinates(
        coordinates: pts,
        padding: const EdgeInsets.fromLTRB(60, 60, 60, 120),
        maxZoom: 15,
      ));
    }
  }

  /// Fly to one page and open its card (used by the chips under the map).
  void focus(String pageId) {
    for (final p in widget.pages) {
      if (p.id == pageId) {
        setState(() => _selectedId = p.id);
        if (_ready) {
          _map.move(p.point, _map.camera.zoom < 14 ? 14 : _map.camera.zoom);
        }
        return;
      }
    }
  }

  void _zoom(double by) {
    if (!_ready) return;
    final c = _map.camera;
    _map.move(c.center, (c.zoom + by).clamp(3, 18).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = _selected;
    final pins = widget.pages.toList()
      // The selected pin is drawn last so it sits on top.
      ..sort((a, b) => (a.id == _selectedId ? 1 : 0) - (b.id == _selectedId ? 1 : 0));

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.pages.isNotEmpty
                  ? widget.pages.first.point
                  : widget.fallbackCenter,
              initialZoom: 11.5,
              minZoom: 3,
              maxZoom: 18,
              backgroundColor:
                  isDark ? const Color(0xFF0E1117) : const Color(0xFFEFF1F4),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onMapReady: () {
                _ready = true;
                fitAll();
              },
              onTap: (_, __) {
                if (_selectedId != null) setState(() => _selectedId = null);
              },
            ),
            children: [
              TileLayer(
                // Carto basemaps (OpenStreetMap data): clean, with a dark
                // version for dark mode.
                urlTemplate: isDark
                    ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
                    : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                retinaMode: RetinaMode.isHighDensity(context),
                userAgentPackageName: AppConstants.mapUserAgent,
              ),
              MarkerLayer(
                markers: [
                  for (final p in pins)
                    Marker(
                      point: p.point,
                      width: 56,
                      height: 64,
                      alignment: Alignment.topCenter,
                      child: _Pin(
                        page: p,
                        selected: p.id == _selectedId,
                        onTap: () => setState(() =>
                            _selectedId = _selectedId == p.id ? null : p.id),
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Top-left: how many pages are on the map.
          Positioned(
            left: 12,
            top: 12,
            child: _Glass(
              isDark: isDark,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (widget.loading) ...[
                    const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                  ] else ...[
                    const Icon(Icons.storefront_rounded,
                        size: 15, color: AppColors.primary),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    widget.pages.length == 1
                        ? tr('1 page on the map')
                        : '${widget.pages.length} ${tr('pages on the map')}',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ]),
              ),
            ),
          ),

          // Right side: zoom and "show all".
          Positioned(
            right: 12,
            top: 12,
            child: _Glass(
              isDark: isDark,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _MapButton(
                    icon: Icons.add_rounded,
                    tip: tr('Zoom in'),
                    onTap: () => _zoom(1)),
                const SizedBox(width: 30, child: Divider(height: 1)),
                _MapButton(
                    icon: Icons.remove_rounded,
                    tip: tr('Zoom out'),
                    onTap: () => _zoom(-1)),
                const SizedBox(width: 30, child: Divider(height: 1)),
                _MapButton(
                    icon: Icons.fit_screen_rounded,
                    tip: tr('Show all pages'),
                    onTap: fitAll),
              ]),
            ),
          ),

          if (widget.pages.isEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _Glass(
                    isDark: isDark,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.location_searching_rounded,
                            color: AppColors.primary),
                        const SizedBox(height: 6),
                        Text(
                          widget.loading
                              ? tr('Finding page locations...')
                              : tr('No page locations to show yet'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('Pages appear here when they add a location.'),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.grey),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),

          // Bottom: the card of the tapped page.
          Positioned(
            left: 12,
            right: 12,
            bottom: 26,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(
                          begin: const Offset(0, 0.15), end: Offset.zero)
                      .animate(a),
                  child: child,
                ),
              ),
              child: selected == null
                  ? const SizedBox.shrink()
                  : _PageCard(
                      key: ValueKey(selected.id),
                      page: selected,
                      isDark: isDark,
                      onOpen: () => widget.onOpenPage(selected.id),
                      onClose: () => setState(() => _selectedId = null),
                    ),
            ),
          ),

          // Map data credit (required by OpenStreetMap / Carto).
          Positioned(
            right: 8,
            bottom: 4,
            child: Text(
              '© OpenStreetMap · © CARTO',
              style: TextStyle(
                fontSize: 9.5,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.page, required this.selected, required this.onTap});

  final MapPage page;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final letter =
        page.name.trim().isEmpty ? '?' : page.name.trim()[0].toUpperCase();
    final url = page.imageUrl;
    return Tooltip(
      message: page.name,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedScale(
            scale: selected ? 1.15 : 1,
            alignment: Alignment.bottomCenter,
            duration: const Duration(milliseconds: 160),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 46,
                height: 46,
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? AppColors.primary : Colors.white,
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 8,
                        offset: Offset(0, 3)),
                  ],
                ),
                child: ClipOval(
                  child: url != null && url.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          memCacheWidth: 120,
                          errorWidget: (_, __, ___) => _Letter(letter),
                          placeholder: (_, __) => _Letter(letter),
                        )
                      : _Letter(letter),
                ),
              ),
              // The little point under the logo.
              CustomPaint(
                size: const Size(14, 9),
                painter: _PointPainter(
                    selected ? AppColors.primary : Colors.white),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter(this.letter);
  final String letter;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary.withValues(alpha: 0.15),
      alignment: Alignment.center,
      child: Text(letter,
          style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
              fontSize: 17)),
    );
  }
}

class _PointPainter extends CustomPainter {
  _PointPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawShadow(path, Colors.black, 2, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PointPainter old) => old.color != color;
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    super.key,
    required this.page,
    required this.isDark,
    required this.onOpen,
    required this.onClose,
  });

  final MapPage page;
  final bool isDark;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final sub = [page.category, page.place].where((s) => s.isNotEmpty).join(' · ');
    final url = page.imageUrl;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Material(
          elevation: 8,
          shadowColor: Colors.black38,
          color: isDark ? const Color(0xFF1A202C) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
              child: Row(children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                  backgroundImage: url != null && url.isNotEmpty
                      ? CachedNetworkImageProvider(url)
                      : null,
                  child: url == null || url.isEmpty
                      ? Text(
                          page.name.isEmpty ? '?' : page.name[0].toUpperCase(),
                          style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800))
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(page.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 15)),
                        ),
                        if (page.verified) ...[
                          const SizedBox(width: 4),
                          const VerifiedBadge(size: 15),
                        ],
                      ]),
                      if (sub.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.grey)),
                      ],
                      if (OpeningHours.fromData(page.hours) != null) ...[
                        const SizedBox(height: 4),
                        OpenStatusChip(hours: page.hours),
                      ],
                    ],
                  ),
                ),
                if (page.mapsLink.isNotEmpty)
                  IconButton(
                    tooltip: tr('Directions'),
                    icon: const Icon(Icons.directions_rounded,
                        color: AppColors.primary),
                    onPressed: () {
                      final uri = Uri.tryParse(page.mapsLink);
                      if (uri != null) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                  ),
                FilledButton(
                  onPressed: onOpen,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(tr('Open')),
                ),
                IconButton(
                  tooltip: tr('Close'),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: onClose,
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child, required this.isDark});
  final Widget child;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: (isDark ? const Color(0xFF151A24) : Colors.white)
          .withValues(alpha: 0.94),
      elevation: 3,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 20)),
      ),
    );
  }
}
