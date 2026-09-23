import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// One place on a phone's bottom bar: an icon over its name, the whole slot pressable.
class BarItem {
  const BarItem({
    required this.icon,
    required this.label,
    this.onTap,
    this.iconOn,
    this.on,
    this.toggle = true,
    this.accent = false,
    this.menu,
    this.menuController,
    this.onMenuChanged,
    this.key,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// A toggle: [on] says whether it is, [iconOn] is the filled icon it shows then.
  final bool? on;
  final IconData? iconOn;

  /// [on] switches something (Unread), rather than saying where one is (Search).
  final bool toggle;

  /// Compose: the accent colour, on or not.
  final bool accent;

  /// A menu that opens upwards from the slot (More), with its controller when the
  /// screen needs to close it (back), and a call when it opens or closes.
  final List<Widget>? menu;
  final MenuController? menuController;
  final VoidCallback? onMenuChanged;
  final Key? key;
}

/// The phone's bottom bar: equal slots, 56 tall above the home indicator, on `bg2`
/// under a hairline. The keyboard covers it while typing.
class PhoneBottomBar extends StatelessWidget {
  const PhoneBottomBar({super.key, required this.items});
  final List<BarItem> items;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.bg2,
        border: Border(top: BorderSide(color: s.border)),
      ),
      child: SafeArea(
        top: false,
        // Labels grow with the system text size up to what 56 holds, as tab bars do.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: SizedBox(
            height: Touch.bottomBar,
            child: Row(
              children: [
                for (final item in items) Expanded(child: _Slot(item: item)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.item});
  final BarItem item;

  @override
  Widget build(BuildContext context) {
    final menu = item.menu;
    if (menu == null) return _body(context, item.onTap);
    return MenuAnchor(
      // A tap outside closes the menu and does nothing else.
      consumeOutsideTap: true,
      controller: item.menuController,
      onOpen: item.onMenuChanged,
      onClose: item.onMenuChanged,
      alignmentOffset: const Offset(0, 4),
      menuChildren: menu,
      builder: (context, controller, _) => _body(
        context,
        item.onTap == null && menu.isEmpty
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _body(BuildContext context, VoidCallback? onTap) {
    final s = context.s;
    final on = item.on ?? false;
    final enabled = onTap != null;
    final color = item.accent || on ? s.accentStrong : s.fg2;
    return Semantics(
      key: item.key,
      button: true,
      enabled: enabled,
      toggled: item.toggle ? item.on : null,
      selected: item.toggle ? null : item.on,
      label: item.label,
      onTap: onTap,
      excludeSemantics: true,
      child: HoverRegion(
        onTap: onTap,
        builder: (context, pressed) => AnimatedOpacity(
          opacity: enabled ? 1 : 0.4,
          duration: Motion.of(context, Motion.fast),
          child: Container(
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: pressed && enabled ? s.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(Touch.radius),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.fast),
                  child: Icon(
                    on ? item.iconOn ?? item.icon : item.icon,
                    key: ValueKey(on),
                    size: 24,
                    color: color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: ui(
                    context,
                    size: 12,
                    weight: on ? FontWeight.w600 : FontWeight.w500,
                    color: item.accent ? s.accentStrong : (on ? s.fg : s.fg2),
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of a phone menu: 48 tall (56 with a second line), the title in reading type, a
/// detail at the end.
class PhoneMenuItem extends StatelessWidget {
  const PhoneMenuItem({
    super.key,
    required this.title,
    this.onPressed,
    this.subtitle,
    this.subtitleColor,
    this.leading,
    this.trailing,
    this.danger = false,
  });
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final enabled = onPressed != null;
    return MenuItemButton(
      onPressed: onPressed,
      leadingIcon: leading,
      trailingIcon: trailing,
      style: MenuItemButton.styleFrom(
        minimumSize: Size(200, subtitle == null ? Touch.row : 56),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(
                context,
                size: 16,
                color: !enabled
                    ? s.fg3
                    : danger
                    ? s.red
                    : s.fg,
                height: 1.3,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(
                  context,
                  size: 13,
                  color: subtitleColor ?? s.fg2,
                  height: 1.3,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
