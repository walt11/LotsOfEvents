package net.jwalter.lotsofevents;

import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;

final class WidgetData {
  static final String[] NAMES = {
    "Upcoming Agenda",
    "Three-Day Agenda",
    "Next Up",
    "Events + Tasks",
    "Five-Day Strip",
    "Month + Agenda",
    "Focus List",
    "Open Time",
    "Tomorrow Brief",
    "Catch Up",
    "Today Reminders"
  };

  record Line(String title, String subtitle, Store.Item item, boolean heading) {}

  static long start(LocalDate d) {
    return d.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli();
  }

  static List<Line> build(
      int kind,
      List<Store.Item> items,
      LocalDate selected,
      int days,
      boolean showTimes,
      int startHour,
      int endHour) {
    LocalDate today = LocalDate.now();
    long now = System.currentTimeMillis();
    List<Line> out = new ArrayList<>();
    if (kind == 7) {
      long a = Math.max(now, start(today) + startHour * 3600000L),
          end = start(today) + endHour * 3600000L;
      List<Store.Item> busy =
          items.stream()
              .filter(i -> !i.task() && i.end() > a && i.start() < end)
              .sorted(Comparator.comparingLong(Store.Item::start))
              .collect(java.util.stream.Collectors.toList());
      long cursor = a;
      for (var i : busy) {
        if (i.start() - cursor >= 30 * 60000L)
          out.add(
              new Line(
                  ((i.start() - cursor) / 60000) + " minutes free",
                  clock(cursor) + "–" + clock(i.start()),
                  null,
                  false));
        cursor = Math.max(cursor, i.end());
      }
      if (end - cursor >= 30 * 60000L)
        out.add(
            new Line(
                ((end - cursor) / 60000) + " minutes free",
                clock(cursor) + "–" + clock(end),
                null,
                false));
      return out;
    }
    if (kind == 2) {
      var upcoming =
          items.stream()
              .filter(i -> !i.task() && !i.allDay() && i.end() > now)
              .sorted(Comparator.comparingLong(Store.Item::start))
              .collect(java.util.stream.Collectors.toList());
      for (var i : upcoming) {
        out.add(
            new Line(
                i.start() <= now ? "NOW" : "IN " + Math.max(1, (i.start() - now) / 60000) + " MIN",
                "",
                null,
                true));
        out.add(line(i, showTimes));
        if (out.size() >= 4) break;
      }
      return out;
    }
    if (kind == 3) {
      section(
          out,
          "TODAY",
          items.stream()
              .filter(i -> !i.task() && overlaps(i, today))
              .collect(java.util.stream.Collectors.toList()),
          showTimes);
      section(
          out,
          "OVERDUE",
          items.stream()
              .filter(i -> i.task() && i.start() > 0 && i.start() < start(today))
              .collect(java.util.stream.Collectors.toList()),
          showTimes);
      section(
          out,
          "TASKS TODAY",
          items.stream()
              .filter(
                  i ->
                      i.task() && i.start() >= start(today) && i.start() < start(today.plusDays(1)))
              .collect(java.util.stream.Collectors.toList()),
          showTimes);
      section(
          out,
          "ANYTIME",
          items.stream()
              .filter(i -> i.task() && i.start() == 0)
              .collect(java.util.stream.Collectors.toList()),
          showTimes);
      for (int n = 1; n < days; n++) {
        LocalDate d = today.plusDays(n);
        section(
            out,
            dateLabel(d),
            items.stream()
                .filter(i -> overlaps(i, d))
                .collect(java.util.stream.Collectors.toList()),
            showTimes);
      }
      return out;
    }
    if (kind == 6 || kind == 9 || kind == 10) {
      for (var i : items)
        if (i.task()
            && (kind == 6
                || kind == 9 && i.start() > 0 && i.start() < now
                || kind == 10 && (i.start() == 0 || i.start() < start(today.plusDays(1)))))
          out.add(line(i, showTimes));
      return out;
    }
    if (kind == 1 || kind == 4 || kind == 5 || kind == 8) {
      LocalDate day = kind == 8 ? today.plusDays(1) : selected;
      for (var i : items) if (overlaps(i, day)) out.add(line(i, showTimes));
      return out;
    }
    for (int n = 0; n < days; n++) {
      LocalDate d = today.plusDays(n);
      section(
          out,
          dateLabel(d),
          items.stream().filter(i -> overlaps(i, d)).collect(java.util.stream.Collectors.toList()),
          showTimes);
    }
    return out;
  }

  static boolean overlaps(Store.Item i, LocalDate d) {
    return i.start() > 0
        && i.start() < start(d.plusDays(1))
        && Math.max(i.start() + 1, i.end()) > start(d);
  }

  static String clock(long t) {
    return Instant.ofEpochMilli(t)
        .atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofPattern("h:mm a"));
  }

  static String dateLabel(LocalDate d) {
    return d.equals(LocalDate.now().plusDays(1))
        ? "TOMORROW"
        : d.format(DateTimeFormatter.ofPattern("EEE, MMM d")).toUpperCase(Locale.getDefault());
  }

  private static Line line(Store.Item i, boolean times) {
    return new Line(
        i.title(),
        times && !i.allDay() && i.start() > 0
            ? clock(i.start()) + (i.task() ? "" : "–" + clock(i.end()))
            : "",
        i,
        false);
  }

  private static void section(List<Line> out, String name, List<Store.Item> items, boolean times) {
    if (items.isEmpty()) return;
    out.add(new Line(name, "", null, true));
    for (var i : items) out.add(line(i, times));
  }
}
