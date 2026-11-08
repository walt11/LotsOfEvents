package net.jwalter.lotsofevents;

import static org.junit.Assert.*;

import java.time.*;
import org.junit.Test;

public class ContactDatesTest {
  @Test
  public void parsesAppleAnniversaryAndUnknownBirthdayYear() {
    var records =
        ContactDates.parse(
            "BEGIN:VCARD\r\n"
                + "FN:Alex Example\r\n"
                + "UID:1\r\n"
                + "BDAY;X-APPLE-OMIT-YEAR=1604:1604-02-29\r\n"
                + "item1.X-ABDATE:2000-11-08\r\n"
                + "item1.X-ABLabel:_$!<Anniversary>!$_\r\n"
                + "END:VCARD\r\n");
    assertEquals(2, records.size());
    assertEquals(0, records.get(0).year());
    assertEquals("Anniversary", records.get(1).label());
    long start =
        LocalDate.of(2026, 11, 8).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli();
    var items = ContactDates.occurrences(records, start, start + 86400000, 0);
    assertEquals(1, items.size());
    assertTrue(items.get(0).title().contains("26 years"));
  }
}
