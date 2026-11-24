part of '../chat_page.dart';

/// Chat bubble for a location message: a small map with the sender's pin,
/// "Live until 15:30 · updated 1 min ago", and Stop for your own live share.
class _LocationMessageCard extends StatelessWidget {
  const _LocationMessageCard({
    required this.chatId,
    required this.messageId,
    required this.data,
    required this.isMe,
    required this.isDark,
    required this.senderName,
    this.senderAvatar,
  });

  final String chatId;
  final String messageId;
  final Map<String, dynamic> data;
  final bool isMe;
  final bool isDark;
  final String senderName;
  final String? senderAvatar;

  @override
  Widget build(BuildContext context) {
    final loc = data['location'] as Map;
    final point = LatLng(
      (loc['lat'] as num).toDouble(),
      (loc['lng'] as num).toDouble(),
    );
    final info = LocationInfo.fromMessage(data);
    final textColor = isMe ? Colors.white : (isDark ? Colors.white : Colors.black87);
    final subColor = isMe ? Colors.white70 : AppColors.grey;

    void open() {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LocationMapPage(
          chatId: chatId,
          messageId: messageId,
          senderName: senderName,
          senderAvatar: senderAvatar,
        ),
      ));
    }

    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: open,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 130,
                child: AbsorbPointer(
                  child: FlutterMap(
                    // A new key when the pin moves, so the preview follows it.
                    key: ValueKey('${point.latitude},${point.longitude}'),
                    options: MapOptions(
                      initialCenter: point,
                      initialZoom: 15,
                      interactionOptions:
                          const InteractionOptions(flags: InteractiveFlag.none),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: AppConstants.mapTileUrl,
                        userAgentPackageName: AppConstants.mapUserAgent,
                      ),
                      MarkerLayer(markers: [
                        Marker(
                          point: point,
                          width: 40,
                          height: 50,
                          alignment: Alignment.topCenter,
                          child: AvatarPin(
                            name: senderName,
                            imageUrl: senderAvatar,
                            live: info.isLiveNow,
                            size: 34,
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                info.isLiveNow ? Icons.share_location_rounded : Icons.location_on_rounded,
                size: 18,
                color: info.isLiveNow ? AppColors.secondary : textColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  info.statusLine(),
                  style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (info.isLive)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 24),
              child: Text(info.updatedLine(),
                  style: TextStyle(color: subColor, fontSize: 12)),
            ),
          if (isMe && info.isLiveNow)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => LiveLocationService.instance.stop(messageId),
                style: TextButton.styleFrom(
                  foregroundColor: isMe ? Colors.white : AppColors.error,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Stop sharing'),
              ),
            ),
        ],
      ),
    );
  }
}
