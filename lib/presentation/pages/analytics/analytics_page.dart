import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../../core/theme/colors.dart';
import '../feed/post_detail_page.dart';

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please sign in.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Insights'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),
        builder: (context, userSnap) {
          final userData =
              userSnap.data?.data() as Map<String, dynamic>? ?? {};
          final userType = (userData['userType'] ?? 'client').toString();

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('posts')
                .where('ownerId', isEqualTo: user.uid)
                .snapshots(),
            builder: (context, postsSnap) {
              final postDocs = postsSnap.data?.docs ?? [];
              int totalLikes = 0;
              int totalComments = 0;
              final now = DateTime.now();
              final dailyCounts = List<int>.filled(7, 0);
              for (final doc in postDocs) {
                final data = doc.data() as Map<String, dynamic>;
                final likes = (data['likes'] as List?)?.length ?? 0;
                final comments = (data['comments'] as List?)?.length ?? 0;
                totalLikes += likes;
                totalComments += comments;
                final createdAt = data['createdAt'] as Timestamp?;
                if (createdAt != null) {
                  final date = createdAt.toDate();
                  final diff = now.difference(DateTime(date.year, date.month, date.day)).inDays;
                  if (diff >= 0 && diff < 7) {
                    dailyCounts[6 - diff] += 1;
                  }
                }
              }

              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .collection('favorites')
                    .snapshots(),
                builder: (context, favSnap) {
                  final favoritesCount = favSnap.data?.docs.length ?? 0;

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('chats')
                        .where('participants', arrayContains: user.uid)
                        .snapshots(),
                    builder: (context, chatsSnap) {
                      final chatDocs = chatsSnap.data?.docs ?? [];
                      int unread = 0;
                      for (final doc in chatDocs) {
                        final data = doc.data() as Map<String, dynamic>;
                        final lastMessageAt =
                            data['lastMessageAt'] as Timestamp?;
                        final lastMessageSenderId =
                            data['lastMessageSenderId'] as String?;
                        final lastReadAt =
                            data['lastReadAt'] as Map<String, dynamic>? ?? {};
                        final lastReadForUser =
                            lastReadAt[user.uid] as Timestamp?;
                        final isUnread = lastMessageAt != null &&
                            (lastReadForUser == null ||
                                lastMessageAt
                                    .toDate()
                                    .isAfter(lastReadForUser.toDate()));
                        if (isUnread && lastMessageSenderId != user.uid) {
                          unread++;
                        }
                      }

                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('notifications')
                            .where('toUserId', isEqualTo: user.uid)
                            .snapshots(),
                        builder: (context, notifSnap) {
                          final notifDocs = notifSnap.data?.docs ?? [];
                          final unreadNotifs = notifDocs.where((doc) {
                            final data = doc.data() as Map<String, dynamic>;
                            return data['readAt'] == null &&
                                data['hidden'] != true;
                          }).length;

                          final cards = <Widget>[
                            _StatCard(
                              title: 'Saved',
                              value: favoritesCount.toString(),
                              icon: Icons.bookmark,
                            ),
                            _StatCard(
                              title: 'Chats',
                              value: chatDocs.length.toString(),
                              icon: Icons.chat_bubble_outline,
                              subtitle:
                                  unread > 0 ? '$unread unread' : 'All read',
                            ),
                            _StatCard(
                              title: 'Notifications',
                              value: unreadNotifs.toString(),
                              icon: Icons.notifications_none,
                              subtitle:
                                  unreadNotifs > 0 ? 'New' : 'All caught up',
                            ),
                          ];

                          if (userType == 'business') {
                            cards.insertAll(0, [
                              _StatCard(
                                title: 'Posts',
                                value: postDocs.length.toString(),
                                icon: Icons.article_outlined,
                                footer: _MiniSparkline(values: dailyCounts),
                              ),
                              _StatCard(
                                title: 'Likes',
                                value: totalLikes.toString(),
                                icon: Icons.star_border,
                                footer: _ProgressLine(
                                  value: totalLikes,
                                  target: 1000,
                                  color: Colors.amber,
                                  label: 'Target 1k',
                                ),
                              ),
                              _StatCard(
                                title: 'Comments',
                                value: totalComments.toString(),
                                icon: Icons.comment_outlined,
                                footer: _ProgressLine(
                                  value: totalComments,
                                  target: 500,
                                  color: Colors.lightBlueAccent,
                                  label: 'Target 500',
                                ),
                              ),
                            ]);
                          }

                          final totalEngagement = totalLikes + totalComments;
                          final weeklyPosts = dailyCounts.fold<int>(
                            0,
                            (sum, count) => sum + count,
                          );
                          final bestDayPosts = dailyCounts.isEmpty
                              ? 0
                              : dailyCounts.reduce(
                                  (a, b) => a > b ? a : b,
                                );
                          final avgLikesPerPost = postDocs.isEmpty
                              ? 0.0
                              : totalLikes / postDocs.length;
                          final avgCommentsPerPost = postDocs.isEmpty
                              ? 0.0
                              : totalComments / postDocs.length;

                          return DefaultTabController(
                            length: 2,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final isDesktop = constraints.maxWidth >= 1100;
                                final cardCount = cards.length < 4 ? cards.length : 4;

                                final overviewPanel = _InsightSectionCard(
                                  title: 'Activity trend',
                                  subtitle: 'Posts published across the last 7 days',
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _WeeklyBarsChart(values: dailyCounts, isDesktop: isDesktop),
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 10,
                                        runSpacing: 10,
                                        children: [
                                          _InsightBadge(
                                            icon: Icons.local_fire_department_rounded,
                                            label: 'Peak day: $bestDayPosts posts',
                                          ),
                                          _InsightBadge(
                                            icon: Icons.calendar_view_week_rounded,
                                            label: '$weeklyPosts posts this week',
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );

                                final engagementPanel = _InsightSectionCard(
                                  title: 'Engagement mix',
                                  subtitle: 'How likes and comments are split right now',
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Center(
                                        child: SizedBox(
                                          width: isDesktop ? 200 : 160,
                                          height: isDesktop ? 200 : 160,
                                          child: Stack(
                                            alignment: Alignment.center,
                                            children: [
                                              PieChart(
                                                PieChartData(
                                                  sections: [
                                                    PieChartSectionData(
                                                      value: totalLikes.toDouble(),
                                                      color: Colors.amber,
                                                      title: totalLikes > 0 ? '${((totalLikes / (totalLikes + totalComments)) * 100).toStringAsFixed(0)}%' : '0%',
                                                      radius: isDesktop ? 60 : 50,
                                                      titleStyle: TextStyle(
                                                        fontSize: isDesktop ? 14 : 12,
                                                        fontWeight: FontWeight.bold,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                    PieChartSectionData(
                                                      value: totalComments.toDouble(),
                                                      color: Colors.lightBlueAccent,
                                                      title: totalComments > 0 ? '${((totalComments / (totalLikes + totalComments)) * 100).toStringAsFixed(0)}%' : '0%',
                                                      radius: isDesktop ? 60 : 50,
                                                      titleStyle: TextStyle(
                                                        fontSize: isDesktop ? 14 : 12,
                                                        fontWeight: FontWeight.bold,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ],
                                                  sectionsSpace: 2,
                                                  centerSpaceRadius: 30,
                                                ),
                                              ),
                                              Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    totalEngagement.toString(),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .headlineSmall
                                                        ?.copyWith(
                                                          fontWeight: FontWeight.w800,
                                                        ),
                                                  ),
                                                  const Text(
                                                    'total actions',
                                                    style: TextStyle(
                                                      color: AppColors.grey,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Row(
                                        children: [
                                          Container(
                                            width: 12,
                                            height: 12,
                                            decoration: const BoxDecoration(
                                              color: Colors.amber,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          const Text(
                                            'Likes',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                          const SizedBox(width: 16),
                                          Container(
                                            width: 12,
                                            height: 12,
                                            decoration: const BoxDecoration(
                                              color: Colors.lightBlueAccent,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          const Text(
                                            'Comments',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      _MetricRow(
                                        label: 'Likes per post',
                                        value: avgLikesPerPost.toStringAsFixed(1),
                                        color: Colors.amber,
                                      ),
                                      const SizedBox(height: 10),
                                      _MetricRow(
                                        label: 'Comments per post',
                                        value: avgCommentsPerPost.toStringAsFixed(1),
                                        color: Colors.lightBlueAccent,
                                      ),
                                      const SizedBox(height: 10),
                                      _MetricRow(
                                        label: 'Unread chats',
                                        value: unread.toString(),
                                        color: Colors.green,
                                      ),
                                    ],
                                  ),
                                );

                                return SingleChildScrollView(
                                  padding: EdgeInsets.all(isDesktop ? 20 : 16),
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: isDesktop ? constraints.maxWidth : 760,
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            padding: EdgeInsets.all(isDesktop ? 20 : 16),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).brightness ==
                                                      Brightness.dark
                                                  ? const Color(0xFF171B24)
                                                  : Colors.white,
                                              borderRadius: BorderRadius.circular(20),
                                              border: Border.all(
                                                color: Theme.of(context).brightness ==
                                                        Brightness.dark
                                                    ? Colors.white10
                                                    : Colors.black12,
                                              ),
                                            ),
                                            child: isDesktop
                                                ? Row(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment.start,
                                                    children: [
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment.start,
                                                          children: [
                                                            Text(
                                                              userType == 'business'
                                                                  ? 'Business insights dashboard'
                                                                  : 'Your insights dashboard',
                                                              style: Theme.of(context)
                                                                  .textTheme
                                                                  .headlineSmall
                                                                  ?.copyWith(
                                                                    fontWeight:
                                                                        FontWeight.w800,
                                                                  ),
                                                            ),
                                                            const SizedBox(height: 8),
                                                            Text(
                                                              userType == 'business'
                                                                  ? 'Desktop view now gives you a cleaner snapshot of engagement, posting rhythm, and community activity.'
                                                                  : 'Track your saved items, inbox activity, and notifications with a wider desktop overview.',
                                                              style: TextStyle(
                                                                color: Theme.of(context)
                                                                            .brightness ==
                                                                        Brightness.dark
                                                                    ? Colors.white70
                                                                    : AppColors.grey,
                                                              ),
                                                            ),
                                                            const SizedBox(height: 14),
                                                            Wrap(
                                                              spacing: 10,
                                                              runSpacing: 10,
                                                              children: [
                                                                _InsightBadge(
                                                                  icon: Icons.bar_chart_rounded,
                                                                  label:
                                                                      '$weeklyPosts posts this week',
                                                                ),
                                                                _InsightBadge(
                                                                  icon: Icons.favorite_border_rounded,
                                                                  label:
                                                                      '$totalEngagement total engagement',
                                                                ),
                                                                _InsightBadge(
                                                                  icon:
                                                                      Icons.bookmark_border_rounded,
                                                                  label:
                                                                      '$favoritesCount saved items',
                                                                ),
                                                              ],
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(width: 16),
                                                      Expanded(
                                                        flex: 4,
                                                        child: _InsightSectionCard(
                                                          title: 'Quick pulse',
                                                          subtitle:
                                                              'A fast desktop summary',
                                                          child: Column(
                                                            children: [
                                                              _MetricRow(
                                                                label: 'Unread notifications',
                                                                value: unreadNotifs.toString(),
                                                                color: AppColors.primary,
                                                              ),
                                                              const SizedBox(height: 10),
                                                              _MetricRow(
                                                                label: 'Open chats',
                                                                value: chatDocs.length.toString(),
                                                                color: Colors.deepPurple,
                                                              ),
                                                              const SizedBox(height: 10),
                                                              _MetricRow(
                                                                label: 'Published posts',
                                                                value: postDocs.length.toString(),
                                                                color: Colors.orange,
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        'Insights overview',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleLarge
                                                            ?.copyWith(
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                      ),
                                                      const SizedBox(height: 8),
                                                      const Text(
                                                        'Your stats, posts, and activity in one place.',
                                                        style: TextStyle(
                                                          color: AppColors.grey,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 12),
                                                      Wrap(
                                                        spacing: 8,
                                                        runSpacing: 8,
                                                        children: [
                                                          _InsightBadge(
                                                            icon: Icons.bar_chart_rounded,
                                                            label:
                                                                '$weeklyPosts this week',
                                                          ),
                                                          _InsightBadge(
                                                            icon: Icons.favorite_border_rounded,
                                                            label:
                                                                '$totalEngagement engagement',
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                          ),
                                          const SizedBox(height: 16),
                                          GridView.count(
                                            crossAxisCount: isDesktop ? cardCount : 2,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            childAspectRatio: isDesktop ? 1.5 : 1.25,
                                            shrinkWrap: true,
                                            physics: const NeverScrollableScrollPhysics(),
                                            children: cards,
                                          ),
                                          const SizedBox(height: 16),
                                          if (isDesktop)
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Expanded(flex: 8, child: overviewPanel),
                                                const SizedBox(width: 12),
                                                Expanded(flex: 6, child: engagementPanel),
                                              ],
                                            )
                                          else ...[
                                            overviewPanel,
                                            const SizedBox(height: 12),
                                            engagementPanel,
                                          ],
                                          const SizedBox(height: 16),
                                          _InsightSectionCard(
                                            title: 'Your posts',
                                            subtitle:
                                                'Browse your recent content and saved items',
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .surface,
                                                    borderRadius: BorderRadius.circular(12),
                                                    border: Border.all(
                                                      color: Theme.of(context)
                                                                  .brightness ==
                                                              Brightness.dark
                                                          ? Colors.white10
                                                          : Colors.black12,
                                                    ),
                                                  ),
                                                  child: const TabBar(
                                                    indicatorSize:
                                                        TabBarIndicatorSize.tab,
                                                    tabs: [
                                                      Tab(text: 'Recent Posts'),
                                                      Tab(text: 'Saved'),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                SizedBox(
                                                  height: isDesktop ? 480 : 420,
                                                  child: TabBarView(
                                                    children: [
                                                      _RecentPostsList(
                                                        postDocs: postDocs,
                                                      ),
                                                      _SavedPostsList(
                                                        favoriteDocs:
                                                            favSnap.data?.docs ?? [],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    this.subtitle,
    this.footer,
  });

  final String title;
  final String value;
  final IconData icon;
  final String? subtitle;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                color: isDark ? Colors.white70 : AppColors.grey,
                fontSize: 12,
              ),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: 6),
            footer!,
          ],
        ],
      ),
    );
  }
}

class _InsightSectionCard extends StatelessWidget {
  const _InsightSectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: isDark ? Colors.white70 : AppColors.grey,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _InsightBadge extends StatelessWidget {
  const _InsightBadge({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : AppColors.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: isDark ? Colors.white70 : AppColors.grey,
              fontSize: 12,
            ),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _WeeklyBarsChart extends StatelessWidget {
  const _WeeklyBarsChart({required this.values, this.isDesktop = false});

  final List<int> values;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final safeValues = values.isEmpty ? List<int>.filled(7, 0) : values;
    final maxValue = safeValues.reduce((a, b) => a > b ? a : b);

    return SizedBox(
      height: isDesktop ? 250 : 200,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxValue.toDouble() + 1,
          barTouchData: BarTouchData(enabled: false),
          titlesData: FlTitlesData(
            show: true,
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index >= 0 && index < labels.length) {
                    return Text(
                      labels[index],
                      style: TextStyle(
                        fontSize: isDesktop ? 14 : 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.grey,
                      ),
                    );
                  }
                  return const SizedBox();
                },
                reservedSize: 30,
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  return Text(
                    value.toInt().toString(),
                    style: TextStyle(
                      fontSize: isDesktop ? 12 : 10,
                      color: AppColors.grey,
                    ),
                  );
                },
                reservedSize: 40,
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barGroups: List.generate(safeValues.length, (index) {
            return BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: safeValues[index].toDouble(),
                  color: AppColors.primary,
                  width: isDesktop ? 24 : 20,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

class _RecentPostsList extends StatelessWidget {
  const _RecentPostsList({required this.postDocs});

  final List<QueryDocumentSnapshot> postDocs;

  @override
  Widget build(BuildContext context) {
    if (postDocs.isEmpty) {
      return const Center(child: Text('No posts yet.'));
    }

    final sorted = [...postDocs]
      ..sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;
        final aTs = aData['createdAt'] as Timestamp?;
        final bTs = bData['createdAt'] as Timestamp?;
        return (bTs?.millisecondsSinceEpoch ?? 0)
            .compareTo(aTs?.millisecondsSinceEpoch ?? 0);
      });

    return ListView.separated(
      itemCount: sorted.take(8).length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final data = sorted[index].data() as Map<String, dynamic>;
        return _PostPreviewCard(
          data: data,
          postId: sorted[index].id,
        );
      },
    );
  }
}

class _SavedPostsList extends StatelessWidget {
  const _SavedPostsList({required this.favoriteDocs});

  final List<QueryDocumentSnapshot> favoriteDocs;

  @override
  Widget build(BuildContext context) {
    if (favoriteDocs.isEmpty) {
      return const Center(child: Text('No saved posts.'));
    }

    final ids = favoriteDocs
        .map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return (data['postId'] ?? doc.id).toString();
        })
        .where((id) => id.isNotEmpty)
        .toList();

    if (ids.isEmpty) {
      return const Center(child: Text('No saved posts.'));
    }

    final limited = ids.take(10).toList();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where(FieldPath.documentId, whereIn: limited)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(child: Text('No saved posts.'));
        }
        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            return _PostPreviewCard(
              data: data,
              postId: docs[index].id,
            );
          },
        );
      },
    );
  }
}

class _PostPreviewCard extends StatelessWidget {
  const _PostPreviewCard({
    required this.data,
    required this.postId,
  });

  final Map<String, dynamic> data;
  final String postId;

  @override
  Widget build(BuildContext context) {
    final content = (data['content'] ?? '').toString();
    final likes = (data['likes'] as List?)?.length ?? 0;
    final comments = (data['comments'] as List?)?.length ?? 0;
    final createdAt = data['createdAt'] as Timestamp?;
    final imageUrl = (data['imageUrl'] ?? '').toString();
    final videoUrl = (data['videoUrl'] ?? '').toString();
    final media = data['media'] as List?;
    String? previewUrl;
    bool isVideo = false;
    if (media != null && media.isNotEmpty) {
      final first = media.first;
      if (first is Map && first['url'] != null) {
        previewUrl = first['url'].toString();
        final type = (first['type'] ?? '').toString().toLowerCase();
        isVideo = type == 'video';
      }
    } else if (imageUrl.isNotEmpty) {
      previewUrl = imageUrl;
    } else if (videoUrl.isNotEmpty) {
      previewUrl = videoUrl;
      isVideo = true;
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PostDetailPage(postId: postId),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF171B24)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : Colors.black12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.lightGrey,
                borderRadius: BorderRadius.circular(10),
              ),
              child: previewUrl == null
                  ? const Icon(Icons.image, color: AppColors.grey)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: isVideo
                          ? _VideoThumb(url: previewUrl)
                          : Image.network(
                              previewUrl,
                              fit: BoxFit.cover,
                            ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    content.isEmpty ? 'Post' : content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Likes: $likes  Comments: $comments',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white70
                          : AppColors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              createdAt == null ? '' : _formatDate(createdAt.toDate()),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$month/$day';
}

class _MiniSparkline extends StatelessWidget {
  const _MiniSparkline({required this.values});

  final List<int> values;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final minVal = values.reduce((a, b) => a < b ? a : b);
    final range = (maxVal - minVal).toDouble();
    final dx = size.width / (values.length - 1).clamp(1, values.length);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final v = values[i].toDouble();
      final y = range == 0
          ? size.height * 0.5
          : size.height - ((v - minVal) / range) * size.height;
      final x = i * dx;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.color != color;
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.value,
    required this.target,
    required this.color,
    required this.label,
  });

  final int value;
  final int target;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final progress = (target == 0) ? 0.0 : (value / target).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 6,
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.black12,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : AppColors.grey,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: Platform.isWindows
          ? Future.value(null)
          : VideoThumbnail.thumbnailData(
              video: url,
              imageFormat: ImageFormat.JPEG,
              maxWidth: 240,
              quality: 75,
            ),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return const Center(
            child: Icon(Icons.play_circle_fill, color: Colors.white70),
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes, fit: BoxFit.cover),
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white70),
            ),
          ],
        );
      },
    );
  }
}
