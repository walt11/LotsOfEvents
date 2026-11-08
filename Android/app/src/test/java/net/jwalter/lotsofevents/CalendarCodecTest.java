package net.jwalter.lotsofevents;

import static org.junit.Assert.*;

import java.time.*;
import org.junit.Test;

public class CalendarCodecTest {
  private static long time(String s) {
    return Instant.parse(s).toEpochMilli();
  }

  private static String wrap(String s) {
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Tests//EN\r\n" + s + "END:VCALENDAR\r\n";
  }

  @Test
  public void createRoundTripEscapesTitle() throws Exception {
    long start = time("2026-11-08T15:00:00Z");
    String raw =
        CalendarCodec.create(
            "Call, plan; review", "Line 1\nLine 2", "Home", start, start + 3600000, false);
    var result = CalendarCodec.expand(raw, start - 1, start + 86400000);
    assertEquals(1, result.size());
    assertEquals("Call, plan; review", result.get(0).title());
    assertEquals("Line 1\nLine 2", result.get(0).notes());
  }

  @Test
  public void recurrenceExclusionsAndOverrides() throws Exception {
    String raw =
        wrap(
            "BEGIN:VEVENT\r\n"
                + "UID:abc\r\n"
                + "DTSTART:20261101T150000Z\r\n"
                + "DTEND:20261101T160000Z\r\n"
                + "RRULE:FREQ=DAILY;COUNT=4\r\n"
                + "EXDATE:20261102T150000Z\r\n"
                + "SUMMARY:Original\r\n"
                + "END:VEVENT\r\n"
                + "BEGIN:VEVENT\r\n"
                + "UID:abc\r\n"
                + "RECURRENCE-ID:20261103T150000Z\r\n"
                + "DTSTART:20261103T180000Z\r\n"
                + "DTEND:20261103T190000Z\r\n"
                + "SUMMARY:Moved\r\n"
                + "END:VEVENT\r\n");
    var items =
        CalendarCodec.expand(raw, time("2026-11-01T00:00:00Z"), time("2026-11-06T00:00:00Z"));
    assertEquals(3, items.size());
    assertEquals("Moved", items.get(1).title());
    assertEquals(time("2026-11-03T18:00:00Z"), items.get(1).start());
  }

  @Test
  public void overlapAndAllDayExclusiveEnd() throws Exception {
    String raw =
        wrap(
            "BEGIN:VEVENT\r\n"
                + "UID:all\r\n"
                + "DTSTART;VALUE=DATE:20261101\r\n"
                + "DTEND;VALUE=DATE:20261103\r\n"
                + "SUMMARY:Trip\r\n"
                + "END:VEVENT\r\n");
    long from =
        LocalDate.of(2026, 11, 2).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli();
    assertTrue(CalendarCodec.expand(raw, from, from + 3600000).get(0).allDay());
    long end =
        LocalDate.of(2026, 11, 3).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli();
    assertTrue(CalendarCodec.expand(raw, end, end + 3600000).isEmpty());
  }

  @Test
  public void editKeepsUnrelatedProperties() throws Exception {
    String raw =
        wrap(
            "BEGIN:VEVENT\r\n"
                + "UID:a\r\n"
                + "DTSTART:20261108T150000Z\r\n"
                + "DTEND:20261108T160000Z\r\n"
                + "SUMMARY:Old\r\n"
                + "X-PRIVATE-THING:Keep me\r\n"
                + "END:VEVENT\r\n");
    String edited =
        CalendarCodec.edit(
            raw, "New", "", "", time("2026-11-08T15:00:00Z"), time("2026-11-08T16:00:00Z"), false);
    assertTrue(edited.contains("X-PRIVATE-THING:Keep me"));
    assertTrue(edited.contains("UID:a"));
  }

  @Test
  public void rejectsUntrustedCredentialDestinations() {
    assertTrue(CalDav.trusted("https://p42-caldav.icloud.com/calendar/"));
    assertFalse(CalDav.trusted("https://icloud.com.evil.test/"));
    assertFalse(CalDav.trusted("http://caldav.icloud.com/"));
    assertFalse(CalDav.trusted("https://caldav.icloud.com:8443/"));
    assertFalse(CalDav.trusted("https://user@caldav.icloud.com/"));
  }

  @Test
  public void rejectsExternalXmlEntities() throws Exception {
    try {
      CalDav.xml("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><x>&a;</x>");
      fail();
    } catch (org.xml.sax.SAXException expected) {
    }
  }
}
