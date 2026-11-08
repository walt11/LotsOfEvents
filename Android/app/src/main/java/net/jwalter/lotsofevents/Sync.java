package net.jwalter.lotsofevents;

import android.content.*;
import java.time.*;
import java.util.*;

final class Sync {
  static synchronized void run(Context c) throws Exception {
    String[] credentials = new Vault(c).read();
    if (credentials == null) return;
    CalDav dav = new CalDav(credentials[0], credentials[1]);
    var calendars = dav.discover();
    Map<String, List<CalDav.Resource>> data = new HashMap<>();
    Instant from = LocalDate.now().minusYears(1).atStartOfDay(ZoneId.systemDefault()).toInstant(),
        to = LocalDate.now().plusYears(2).atStartOfDay(ZoneId.systemDefault()).toInstant();
    for (var calendar : calendars) {
      var resources = dav.events(calendar.url(), from, to);
      for (var r : resources)
        CalendarCodec.expand(r.text(), from.toEpochMilli(), to.toEpochMilli());
      data.put(calendar.url(), resources);
    }
    try (Store s = new Store(c)) {
      s.replace(calendars, data);
      if (c.getSharedPreferences("settings", 0).getBoolean("contacts", false)) {
        List<ContactDates.DateRecord> dates = new ArrayList<>();
        for (String card : dav.contacts()) dates.addAll(ContactDates.parse(card));
        s.contacts(dates);
      } else s.contacts(List.of());
    }
    c.getSharedPreferences("settings", 0)
        .edit()
        .putLong("lastSync", System.currentTimeMillis())
        .remove("syncError")
        .apply();
    AgendaWidget.refresh(c);
  }

  static synchronized void disconnect(Context c) {
    new Vault(c).clear();
    try (Store s = new Store(c)) {
      s.disconnect();
    }
    c.getSharedPreferences("settings", 0).edit().remove("lastSync").remove("syncError").apply();
    AgendaWidget.refresh(c);
  }

  static synchronized void connect(Context c, String email, String password) throws Exception {
    new CalDav(email, password).discover();
    new Vault(c).save(email, password);
    try (Store s = new Store(c)) {
      s.disconnect();
    }
    run(c);
    SyncJob.schedule(c);
  }
}
