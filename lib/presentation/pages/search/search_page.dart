import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';

enum SearchFilter { all, businesses, users, places }

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  SearchFilter _filter = SearchFilter.all;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find Services'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Search businesses, users, or places',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: AppColors.lightGrey,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _buildFilterChip(SearchFilter.all, 'All'),
                _buildFilterChip(SearchFilter.businesses, 'Businesses'),
                _buildFilterChip(SearchFilter.users, 'Users'),
                _buildFilterChip(SearchFilter.places, 'Places'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('businesses')
                  .where('isActive', isEqualTo: true)
                  .snapshots(),
              builder: (context, bizSnap) {
                final businesses = (bizSnap.data?.docs ?? [])
                    .map((d) {
                      final data = d.data() as Map<String, dynamic>;
                      return {...data, 'id': d.id};
                    })
                    .toList();

                return StreamBuilder<QuerySnapshot>(
                  stream:
                      FirebaseFirestore.instance.collection('users').snapshots(),
                  builder: (context, userSnap) {
                    final users = (userSnap.data?.docs ?? [])
                        .map((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return {...data, 'id': d.id};
                        })
                        .toList();

                    final results = _buildResults(
                      query: query,
                      businesses: businesses,
                      users: users,
                    );

                    if (results.isEmpty) {
                      return const Center(child: Text('No results'));
                    }

                    return ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = results[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.primary,
                            backgroundImage:
                                item.imageUrl != null ? NetworkImage(item.imageUrl!) : null,
                            child: item.imageUrl == null
                                ? Text(
                                    item.title.isNotEmpty
                                        ? item.title[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          title: Text(item.title),
                          subtitle: Text(item.subtitle),
                          trailing: Icon(item.typeIcon, color: AppColors.grey),
                          onTap: item.onTap,
                        );
                      },
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

  Widget _buildFilterChip(SearchFilter filter, String label) {
    final isSelected = _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: isSelected,
        label: Text(label),
        onSelected: (_) {
          setState(() {
            _filter = filter;
          });
        },
      ),
    );
  }

  List<_SearchItem> _buildResults({
    required String query,
    required List<Map<String, dynamic>> businesses,
    required List<Map<String, dynamic>> users,
  }) {
    final List<_SearchItem> results = [];

    bool matches(String value) {
      if (query.isEmpty) return true;
      return value.toLowerCase().contains(query);
    }

    if (_filter == SearchFilter.all || _filter == SearchFilter.businesses) {
      for (final b in businesses) {
        final name = (b['name'] ?? '').toString();
        final category = (b['category'] ?? '').toString();
        if (matches(name) || matches(category)) {
          results.add(
            _SearchItem(
              title: name.isEmpty ? 'Business' : name,
              subtitle: category.isEmpty ? 'Business' : category,
              imageUrl: b['imageUrl'] as String?,
              typeIcon: Icons.storefront,
              onTap: () {
                final id = b['id'] ?? b['businessId'];
                if (id != null && context.mounted) {
                  context.push(AppRoutes.businessProfilePath(id));
                }
              },
            ),
          );
        }
      }
    }

    if (_filter == SearchFilter.all || _filter == SearchFilter.users) {
      for (final u in users) {
        final name = (u['name'] ?? '').toString();
        final userType = (u['userType'] ?? '').toString();
        if (userType == 'client' && matches(name)) {
          results.add(
            _SearchItem(
              title: name.isEmpty ? 'User' : name,
              subtitle: userType.isEmpty ? 'User' : userType,
              imageUrl: u['imageUrl'] as String?,
              typeIcon: Icons.person,
              onTap: () {
                final id = u['id'] ?? '';
                if (id.toString().isNotEmpty && context.mounted) {
                  context.push(AppRoutes.clientProfilePath(id.toString()));
                }
              },
            ),
          );
        }
      }
    }

    if (_filter == SearchFilter.places) {
      results.add(
        _SearchItem(
          title: 'Place search',
          subtitle: 'Coming soon (map upgrade required)',
          imageUrl: null,
          typeIcon: Icons.place,
          onTap: () {},
        ),
      );
    }

    return results;
  }
}

class _SearchItem {
  final String title;
  final String subtitle;
  final String? imageUrl;
  final IconData typeIcon;
  final VoidCallback onTap;

  _SearchItem({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.typeIcon,
    required this.onTap,
  });
}
