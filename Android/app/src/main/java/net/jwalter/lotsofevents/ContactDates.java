package net.jwalter.lotsofevents;

import java.time.*;
import java.util.*;

final class ContactDates {
  record DateRecord(String id, String name, String label, int year, int month, int day) {}

  static List<DateRecord> parse(String card) {
    String[] lines = card.replaceAll("\\r?\\n[ \\t]", "").split("\\r?\\n");
    String name = "", uid = "";
    Map<String, String> labels = new HashMap<>();
    for (String line : lines) {
      int at = line.indexOf(':');
      if (at < 0) continue;
      String key = line.substring(0, at), value = unescape(line.substring(at + 1));
      if (key.equalsIgnoreCase("FN")) name = value;
      if (key.equalsIgnoreCase("UID")) uid = value;
      if (key.toUpperCase(Locale.ROOT).endsWith(".X-ABLABEL"))
        labels.put(
            key.substring(0, key.indexOf('.')), value.replace("_$!<", "").replace(">!$_", ""));
    }
    List<DateRecord> result = new ArrayList<>();
    for (String line : lines) {
      int at = line.indexOf(':');
      if (at < 0) continue;
      String key = line.substring(0, at),
          base = key.split(";", 2)[0],
          group = base.contains(".") ? base.substring(0, base.indexOf('.')) : "";
      base = base.substring(base.lastIndexOf('.') + 1).toUpperCase(Locale.ROOT);
      if (!base.equals("BDAY") && !base.equals("ANNIVERSARY") && !base.equals("X-ABDATE")) continue;
      String value = line.substring(at + 1).replace("-", "");
      if (value.contains("T")) value = value.substring(0, value.indexOf('T'));
      try {
        int y = value.length() == 8 ? Integer.parseInt(value.substring(0, 4)) : 0,
            m = Integer.parseInt(value.substring(value.length() - 4, value.length() - 2)),
            d = Integer.parseInt(value.substring(value.length() - 2));
        MonthDay.of(m, d);
        if (key.toUpperCase(Locale.ROOT).contains("X-APPLE-OMIT-YEAR")) y = 0;
        String label =
            base.equals("BDAY")
                ? "Birthday"
                : labels.getOrDefault(group, base.equals("ANNIVERSARY") ? "Anniversary" : "Date");
        result.add(
            new DateRecord(uid + "/" + name + "/" + base + "/" + value, name, label, y, m, d));
      } catch (Exception ignored) {
      }
    }
    return result;
  }

  static String unescape(String s) {
    return s.replace("\\n", "\n")
        .replace("\\N", "\n")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\");
  }

  static List<Store.Item> occurrences(List<DateRecord> records, long from, long to, int color) {
    List<Store.Item> result = new ArrayList<>();
    ZoneId zone = ZoneId.systemDefault();
    int first = Instant.ofEpochMilli(from).atZone(zone).getYear(),
        last = Instant.ofEpochMilli(to - 1).atZone(zone).getYear();
    if (last - first > 5) return result;
    for (var r : records)
      for (int y = first; y <= last; y++) {
        if (r.year() > 0 && y < r.year()) continue;
        LocalDate d = MonthDay.of(r.month(), r.day()).atYear(y);
        long start = d.atStartOfDay(zone).toInstant().toEpochMilli(),
            end = d.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli();
        if (end <= from || start >= to) continue;
        String symbol =
            r.label().equalsIgnoreCase("Birthday")
                ? "🎁 "
                : r.label().equalsIgnoreCase("Anniversary") ? "♥ " : "◇ ";
        int years = r.year() > 0 ? y - r.year() : 0;
        String title =
            symbol + r.name() + " · " + r.label() + (years > 0 ? " · " + years + " years" : "");
        result.add(
            new Store.Item(
                "contact:" + r.id() + "/" + y,
                "contacts",
                title,
                "From iCloud Contacts",
                "",
                start,
                end,
                true,
                false,
                false,
                true,
                "",
                "",
                color));
      }
    return result;
  }
}
