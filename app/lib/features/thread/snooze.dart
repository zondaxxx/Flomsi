/// Snooze presets relative to [now] (local time), in the order the picker shows them.
List<(String, DateTime)> snoozeChoices(DateTime now) {
  DateTime at(DateTime day, int hour) =>
      DateTime(day.year, day.month, day.day, hour);
  final today = DateTime(now.year, now.month, now.day);
  final laterToday = now.hour < 15
      ? at(today, 18)
      : DateTime(now.year, now.month, now.day, now.hour + 3);
  final tomorrow = at(today.add(const Duration(days: 1)), 8);
  // Saturday morning; on a weekend, the next one.
  final toSaturday = (DateTime.saturday - now.weekday) % 7;
  final saturday = at(
    today.add(Duration(days: toSaturday == 0 ? 7 : toSaturday)),
    9,
  );
  final toMonday = (DateTime.monday - now.weekday) % 7;
  final monday = at(today.add(Duration(days: toMonday == 0 ? 7 : toMonday)), 8);
  return [
    if (laterToday.day == now.day) ('Later today', laterToday),
    ('Tomorrow', tomorrow),
    if (now.weekday < DateTime.saturday) ('This weekend', saturday),
    ('Next week', monday),
  ];
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `today 18:00`, `tomorrow 08:00`, `Sat 27 Sep 09:00`.
String snoozeLabel(DateTime at, DateTime now) {
  final t = at.toLocal();
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'today $hm';
  if (diff == 1) return 'tomorrow $hm';
  return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]} $hm';
}
