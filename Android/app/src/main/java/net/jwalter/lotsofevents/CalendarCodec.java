package net.jwalter.lotsofevents;

import biweekly.*;
import biweekly.component.*;
import biweekly.util.*;
import java.util.*;

public final class CalendarCodec {
  public record Occurrence(
      String title,
      String notes,
      String location,
      long start,
      long end,
      boolean allDay,
      boolean recurring) {}

  public static List<Occurrence> expand(String text, long from, long to) throws Exception {
    ICalendar cal = Biweekly.parse(text).first();
    if (cal == null) throw new IllegalArgumentException("Invalid calendar data.");
    List<Occurrence> out = new ArrayList<>();
    Set<String> overrides = new HashSet<>();
    for (VEvent e : cal.getEvents())
      if (e.getRecurrenceId() != null)
        overrides.add(e.getUid().getValue() + "/" + e.getRecurrenceId().getValue().getTime());
    for (VEvent e : cal.getEvents()) {
      if (e.getDateStart() == null
          || e.getStatus() != null && "CANCELLED".equalsIgnoreCase(e.getStatus().getValue()))
        continue;
      long start = e.getDateStart().getValue().getTime();
      boolean allDay = !e.getDateStart().getValue().hasTime();
      long duration =
          e.getDateEnd() != null
              ? e.getDateEnd().getValue().getTime() - start
              : e.getDuration() != null
                  ? e.getDuration().getValue().toMillis()
                  : allDay ? 86400000 : 0;
      boolean recurring =
          e.getRecurrenceRule() != null
              || e.getRecurrenceId() != null
              || !e.getRecurrenceDates().isEmpty();
      if (e.getRecurrenceId() != null || !recurring) {
        add(out, e, start, duration, allDay, recurring, from, to);
        continue;
      }
      TimeZone zone = TimeZone.getDefault();
      var tz = cal.getTimezoneInfo().getTimezone(e.getDateStart());
      if (tz != null) zone = tz.getTimeZone();
      else if (!allDay && !cal.getTimezoneInfo().isFloating(e.getDateStart()))
        zone = TimeZone.getTimeZone("UTC");
      var iterator = e.getDateIterator(zone);
      iterator.advanceTo(new Date(from - Math.max(0, duration)));
      int count = 0;
      while (iterator.hasNext()) {
        long next = iterator.next().getTime();
        if (next >= to) break;
        if (++count > 10000)
          throw new IllegalArgumentException(
              "A recurring event has too many occurrences in this range.");
        if (!overrides.contains(e.getUid().getValue() + "/" + next))
          add(out, e, next, duration, allDay, true, from, to);
      }
    }
    out.sort(Comparator.comparingLong(Occurrence::start));
    return out;
  }

  private static void add(
      List<Occurrence> out,
      VEvent e,
      long start,
      long duration,
      boolean allDay,
      boolean recurring,
      long from,
      long to) {
    if (start >= to || start + Math.max(1, duration) <= from) return;
    if (allDay) {
      java.time.ZoneId zone = java.time.ZoneId.systemDefault();
      long days = Math.max(1, Math.round(duration / 86400000.0));
      duration =
          java.time.Instant.ofEpochMilli(start)
                  .atZone(zone)
                  .toLocalDate()
                  .plusDays(days)
                  .atStartOfDay(zone)
                  .toInstant()
                  .toEpochMilli()
              - start;
    }
    out.add(
        new Occurrence(
            e.getSummary() == null ? "Untitled event" : e.getSummary().getValue(),
            e.getDescription() == null ? "" : e.getDescription().getValue(),
            e.getLocation() == null ? "" : e.getLocation().getValue(),
            start,
            start + duration,
            allDay,
            recurring));
  }

  public static String create(
      String title, String notes, String location, long start, long end, boolean allDay) {
    ICalendar cal = new ICalendar();
    VEvent e = new VEvent();
    e.setUid(UUID.randomUUID().toString());
    apply(e, title, notes, location, start, end, allDay);
    cal.addEvent(e);
    return Biweekly.write(cal).go();
  }

  public static String edit(
      String raw,
      String title,
      String notes,
      String location,
      long start,
      long end,
      boolean allDay) {
    ICalendar cal = Biweekly.parse(raw).first();
    if (cal == null || cal.getEvents().size() != 1)
      throw new IllegalArgumentException("Edit this recurring event in Apple Calendar.");
    VEvent e = cal.getEvents().get(0);
    if (e.getRecurrenceRule() != null
        || e.getRecurrenceId() != null
        || !e.getRecurrenceDates().isEmpty())
      throw new IllegalArgumentException("Edit this recurring event in Apple Calendar.");
    apply(e, title, notes, location, start, end, allDay);
    e.setSequence(e.getSequence() == null ? 1 : e.getSequence().getValue() + 1);
    return Biweekly.write(cal).go();
  }

  private static void apply(
      VEvent e, String title, String notes, String location, long start, long end, boolean allDay) {
    if (title.isBlank() || end <= start)
      throw new IllegalArgumentException("Enter a title and an end after the start.");
    e.setSummary(title);
    e.setDescription(notes);
    e.setLocation(location);
    e.setDateStart(new Date(start), !allDay);
    e.setDateEnd(new Date(end), !allDay);
    e.setDateTimeStamp(new Date());
  }
}
