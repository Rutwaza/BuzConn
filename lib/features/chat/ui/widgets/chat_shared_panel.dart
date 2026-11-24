part of '../chat_page.dart';

// Media / Links / Docs lists shown in the chat details panel.
extension _ChatSharedPanel on _ChatPageState {
  Widget _buildSharedMediaGrid(
    List<Map<String, dynamic>> items,
    bool isDark,
  ) {
    if (items.isEmpty) {
      return _buildSharedTabEmptyState(
        icon: Icons.photo_library_outlined,
        label: 'No media shared yet',
      );
    }

    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final url = item['url'] as String;
        final isVideo = item['type'] == 'video';
        return FutureBuilder<String>(
          future: _resolveChatMediaUrl(url),
          builder: (context, resolvedSnapshot) {
            final resolvedUrl = resolvedSnapshot.data;
            if (resolvedUrl == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _scrollToMessage(item['messageId'] as String),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (!isVideo)
                      Image.network(resolvedUrl, fit: BoxFit.cover)
                    else
                      FutureBuilder<Uint8List?>(
                        future: _getVideoThumbnail(resolvedUrl),
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (bytes == null) {
                            return Container(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.black.withValues(alpha: 0.05),
                              child: const Icon(Icons.videocam_rounded),
                            );
                          }
                          return Image.memory(bytes, fit: BoxFit.cover);
                        },
                      ),
                    if (isVideo)
                      Container(
                        color: Colors.black.withValues(alpha: 0.18),
                        child: const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSharedLinksList(
    List<Map<String, dynamic>> items,
    bool isDark,
  ) {
    if (items.isEmpty) {
      return _buildSharedTabEmptyState(
        icon: Icons.link_off_rounded,
        label: 'No shared links yet',
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        final url = item['url'] as String;
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _scrollToMessage(item['messageId'] as String),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.black.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child:
                      const Icon(Icons.link_rounded, color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (item['host'] ?? 'Shared link').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : AppColors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Open link',
                  onPressed: () => _openLink(url),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSharedDocumentsList(
    List<Map<String, dynamic>> items,
    bool isDark,
  ) {
    if (items.isEmpty) {
      return _buildSharedTabEmptyState(
        icon: Icons.folder_open_rounded,
        label: 'No shared documents yet',
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        final size = item['size'] as int?;
        final mediaRef = item['url'] as String;
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            try {
              await _openLink(await _resolveChatMediaUrl(mediaRef));
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open file: $e')),
                );
              }
            }
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.black.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.insert_drive_file_rounded,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (item['name'] ?? 'Document').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (size != null)
                        Text(
                          _formatBytes(size),
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white70 : AppColors.grey,
                          ),
                        ),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Private link expires after 15 minutes',
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 18,
                    color: isDark ? Colors.white54 : AppColors.grey,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSharedTabEmptyState({
    required IconData icon,
    required String label,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.grey, size: 28),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(1)} MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}
