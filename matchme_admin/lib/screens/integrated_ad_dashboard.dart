import 'package:flutter/material.dart';
import 'package:matchme_admin/screens/external_ads_dashboard.dart';
import 'package:matchme_admin/screens/sponsored_ads_dashboard.dart';

typedef AdminTextLookup =
    String Function(String key, {Map<String, String>? params});

/// Hosts the two ad systems behind an Internal / External switch.
///
/// This deliberately does NOT create its own [Scaffold]. The admin shell
/// already provides one with an AppBar (see `_AdminShell` in main.dart); the
/// previous nested `Scaffold(appBar: AppBar(toolbarHeight: 0, ...))` stacked a
/// second Material surface and a zero-height toolbar under the shell's app bar
/// for no benefit. The tab strip is rendered inline instead.
class IntegratedAdDashboard extends StatefulWidget {
  const IntegratedAdDashboard({
    super.key,
    required this.t,
    required this.localeCode,
    required this.textDirection,
  });

  final AdminTextLookup t;
  final String localeCode;
  final TextDirection textDirection;

  @override
  State<IntegratedAdDashboard> createState() => _IntegratedAdDashboardState();
}

class _IntegratedAdDashboardState extends State<IntegratedAdDashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Directionality(
      textDirection: widget.textDirection,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: AnimatedBuilder(
              animation: _tabController,
              builder: (context, _) {
                final internalSelected = _tabController.index == 0;
                return Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    dividerColor: Colors.transparent,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    labelColor: internalSelected
                        ? colorScheme.onPrimary
                        : colorScheme.onTertiary,
                    labelStyle: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    unselectedLabelColor: colorScheme.onSurfaceVariant,
                    unselectedLabelStyle: theme.textTheme.titleSmall,
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicator: BoxDecoration(
                      // Distinct hue per system so the active tab is obvious
                      // at a glance: primary = Internal, tertiary = External.
                      color: internalSelected
                          ? colorScheme.primary
                          : colorScheme.tertiary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    tabs: [
                      Tab(
                        icon: Icon(
                          internalSelected
                              ? Icons.ad_units
                              : Icons.ad_units_outlined,
                        ),
                        text: widget.t('adminInternalSystemTab'),
                      ),
                      Tab(
                        icon: Icon(
                          internalSelected
                              ? Icons.public_outlined
                              : Icons.public,
                        ),
                        text: widget.t('adminExternalSystemTab'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                AdminSponsoredAdsDashboard(
                  t: widget.t,
                  localeCode: widget.localeCode,
                  textDirection: widget.textDirection,
                ),
                AdminExternalAdsDashboard(
                  t: widget.t,
                  localeCode: widget.localeCode,
                  textDirection: widget.textDirection,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
