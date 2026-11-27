import 'package:flutter/material.dart';
import 'package:businessfinder/core/widgets/desktop_width.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_toast.dart';
import '../data/shop_models.dart';
import '../data/shop_repository.dart';
import 'checkout_sheet.dart';

/// "My orders" (things I bought) and "My shop" (orders to my business).
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key, this.startOnShopTab = false});
  final bool startOnShopTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: startOnShopTab ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Orders')),
          bottom: const TabBar(
              tabs: [Tab(text: 'My orders'), Tab(text: 'My shop')]),
        ),
        body: const TabBarView(
            children: [_OrderList(asShop: false), _OrderList(asShop: true)]),
      ),
    );
  }
}

class _OrderList extends StatelessWidget {
  const _OrderList({required this.asShop});
  final bool asShop;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ShopOrder>>(
      stream: ShopRepository().myOrders(asShop: asShop),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Could not load orders: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final orders = snap.data!;
        if (orders.isEmpty) {
          return Center(
            child: Text(
                asShop
                    ? 'No orders to your shop yet.'
                    : 'You have not bought anything yet.',
                style: const TextStyle(color: AppColors.grey)),
          );
        }
        return DesktopWidth(
            child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _OrderCard(order: orders[i], asShop: asShop),
        ));
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.asShop});
  final ShopOrder order;
  final bool asShop;

  Color get _color => switch (order.status) {
        OrderStatus.confirmed => AppColors.success,
        OrderStatus.paidClaimed => AppColors.secondary,
        OrderStatus.notReceived => AppColors.warning,
        OrderStatus.cancelled => AppColors.grey,
        OrderStatus.pendingPayment => AppColors.primary,
        OrderStatus.ready => AppColors.secondary,
        OrderStatus.delivered => AppColors.success,
      };

  @override
  Widget build(BuildContext context) {
    final o = order;
    final repo = ShopRepository();
    final when = o.createdAt == null
        ? ''
        : DateFormat('d MMM, HH:mm').format(o.createdAt!);
    final buttons = <Widget>[];

    if (asShop) {
      if (o.status == OrderStatus.paidClaimed) {
        buttons.addAll([
          OutlinedButton(
            onPressed: () => repo.shopNotReceived(o.id),
            child: Text(tr('Not received')),
          ),
          FilledButton(
            onPressed: () => repo.shopConfirmed(o.id),
            child: Text(tr('Received ✓')),
          ),
        ]);
      } else if (o.status == OrderStatus.pendingPayment ||
          o.status == OrderStatus.notReceived) {
        buttons.add(TextButton(
          onPressed: () => repo.shopConfirmed(o.id),
          child: Text(tr('Mark as paid')),
        ));
      } else if (o.status == OrderStatus.confirmed) {
        buttons.addAll([
          OutlinedButton(
            onPressed: () => repo.shopDelivered(o.id),
            child: Text(tr('Delivered')),
          ),
          FilledButton.icon(
            onPressed: () => repo.shopReady(o.id),
            icon: const Icon(Icons.inventory_2_rounded, size: 18),
            label: Text(tr('Ready')),
          ),
        ]);
      } else if (o.status == OrderStatus.ready) {
        buttons.add(FilledButton.icon(
          onPressed: () => repo.shopDelivered(o.id),
          icon: const Icon(Icons.local_shipping_rounded, size: 18),
          label: Text(tr('Mark delivered')),
        ));
      }
    } else if (o.status == OrderStatus.pendingPayment ||
        o.status == OrderStatus.notReceived) {
      buttons.add(FilledButton(
        onPressed: () => showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => PaySheet(orderId: o.id),
        ),
        child: Text(o.status == OrderStatus.notReceived
            ? 'Check & pay again'
            : 'Pay now'),
      ));
    }

    Widget? deleteRow;
    if (o.isFinished) {
      final from = o.deletableFrom;
      if (o.canDelete) {
        deleteRow = Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text(tr('Delete this order?')),
                  content: Text(tr('It will be removed from your list.')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: Text(tr('Cancel'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: Text(tr('Delete'))),
                  ],
                ),
              );
              if (ok != true) return;
              try {
                await repo.deleteOrder(o.id);
              } catch (e) {
                if (context.mounted) {
                  showToast(context, e.toString(), kind: ToastKind.error);
                }
              }
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(tr('Delete')),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
          ),
        );
      } else if (from != null) {
        final days = from.difference(DateTime.now()).inDays + 1;
        deleteRow = Text(
          '${tr('You can delete this in')} $days ${days == 1 ? tr('day') : tr('days')}',
          style: const TextStyle(fontSize: 11.5, color: AppColors.grey),
        );
      }
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(asShop ? o.summary : o.businessName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(o.status.label,
                    style: TextStyle(
                        color: _color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 4),
            if (!asShop) Text(o.summary),
            Text('${formatRwf(o.total)} · $when',
                style: const TextStyle(color: AppColors.grey)),
            if (asShop && o.txRef != null)
              Text('MoMo transaction ID: ${o.txRef}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            if (asShop && o.status == OrderStatus.paidClaimed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('Check your MoMo SMS for this amount before you tap Received.'),
                  style: const TextStyle(fontSize: 12, color: AppColors.grey),
                ),
              ),
            if (o.status != OrderStatus.cancelled) ...[
              const SizedBox(height: 10),
              OrderTracker(status: o.status),
            ],
            if (buttons.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(alignment: WrapAlignment.end, spacing: 8, children: buttons),
            ],
            if (deleteRow != null) ...[
              const SizedBox(height: 8),
              deleteRow,
            ],
          ],
        ),
      ),
    );
  }
}

/// Ordered → Paid → Confirmed → Ready → Delivered, with the current step lit.
class OrderTracker extends StatelessWidget {
  const OrderTracker({super.key, required this.status});
  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final labels = [
      tr('Ordered'),
      tr('Paid'),
      tr('Confirmed'),
      tr('Ready'),
      tr('Delivered'),
    ];
    final step = status.step;
    final muted = Theme.of(context).colorScheme.outlineVariant;
    final warn = status == OrderStatus.notReceived;
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          Expanded(
            child: Column(
              children: [
                Row(children: [
                  Expanded(
                    child: Container(
                      height: 3,
                      color: i == 0
                          ? Colors.transparent
                          : (i <= step ? AppColors.success : muted),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: i == step ? 18 : 12,
                    height: i == step ? 18 : 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < step || (i == step && !warn)
                          ? AppColors.success
                          : (i == step ? AppColors.warning : muted),
                    ),
                    child: i < step
                        ? const Icon(Icons.check, size: 9, color: Colors.white)
                        : null,
                  ),
                  Expanded(
                    child: Container(
                      height: 3,
                      color: i == labels.length - 1
                          ? Colors.transparent
                          : (i < step ? AppColors.success : muted),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: i == step ? FontWeight.w800 : FontWeight.w500,
                    color: i <= step ? null : AppColors.grey,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
