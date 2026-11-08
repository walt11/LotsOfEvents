package net.jwalter.lotsofevents;

import static org.junit.Assert.*;

import java.time.*;
import java.util.*;
import org.junit.Test;

public class WidgetDataTest {
  Store.Item event(String name, int offset, boolean task) {
    long start = WidgetData.start(LocalDate.now().plusDays(offset)) + 9 * 3600000;
    return new Store.Item(
        name, "Home", name, "", "", start, start + 3600000, false, task, false, false, "", "", 0);
  }

  @Test
  public void threeDaySelectedTodayKeepsFinishedEvents() {
    var item = event("Morning", 0);
    assertEquals(1, WidgetData.build(1, List.of(item), LocalDate.now(), 3, true, 9, 17).size());
  }

  @Test
  public void eventsTasksHonorsDayCount() {
    var items =
        List.of(
            event("Today", 0, false), event("Tomorrow", 1, false), event("Next week", 6, false));
    assertEquals(2, WidgetData.build(3, items, LocalDate.now(), 1, true, 9, 17).size());
    assertEquals(6, WidgetData.build(3, items, LocalDate.now(), 7, true, 9, 17).size());
  }

  @Test
  public void tomorrowBriefExcludesToday() {
    var items = List.of(event("Today", 0, false), event("Tomorrow", 1, true));
    var lines = WidgetData.build(8, items, LocalDate.now(), 5, true, 9, 17);
    assertEquals(1, lines.size());
    assertEquals("Tomorrow", lines.get(0).title());
  }

  @Test
  public void catchUpExcludesUndatedAndFutureTasks() {
    var lines =
        WidgetData.build(
            9,
            List.of(event("Overdue", -1, true), event("Future", 1, true)),
            LocalDate.now(),
            5,
            true,
            9,
            17);
    assertEquals(1, lines.size());
    assertEquals("Overdue", lines.get(0).title());
  }

  private Store.Item event(String n, int d) {
    return event(n, d, false);
  }
}
