package net.jwalter.lotsofevents;

import android.content.*;
import android.database.sqlite.*;
import java.time.*;
import java.util.*;

final class Store extends SQLiteOpenHelper {
  record Item(
      String id,
      String calendar,
      String title,
      String notes,
      String location,
      long start,
      long end,
      boolean allDay,
      boolean task,
      boolean done,
      boolean recurring,
      String raw,
      String etag,
      int color) {}

  record CalendarRow(String id, String name, int color, boolean writable, boolean selected) {}

  private final Context context;

  Store(Context c) {
    super(c, "agenda.db", null, 3);
    context = c.getApplicationContext();
  }

  public void onCreate(SQLiteDatabase d) {
    d.execSQL(
        "CREATE TABLE calendars (id TEXT PRIMARY KEY,name TEXT,color INTEGER,writable"
            + " INTEGER,selected INTEGER)");
    d.execSQL("CREATE TABLE events (id TEXT PRIMARY KEY,calendar TEXT,etag TEXT,raw TEXT)");
    d.execSQL(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY,title TEXT,notes TEXT,due INTEGER,done"
            + " INTEGER,list TEXT DEFAULT 'Reminders')");
    d.execSQL(
        "CREATE TABLE lists (name TEXT PRIMARY KEY,position INTEGER,selected INTEGER,color"
            + " INTEGER)");
    d.execSQL("INSERT INTO lists VALUES ('Reminders',0,1,-5206444)");
    d.execSQL(
        "CREATE TABLE contact_dates (id TEXT PRIMARY KEY,name TEXT,label TEXT,year INTEGER,month"
            + " INTEGER,day INTEGER)");
  }

  public void onUpgrade(SQLiteDatabase d, int a, int b) {
    if (a < 3)
      d.execSQL(
          "CREATE TABLE IF NOT EXISTS contact_dates (id TEXT PRIMARY KEY,name TEXT,label TEXT,year"
              + " INTEGER,month INTEGER,day INTEGER)");
    if (a < 2) {
      d.execSQL("ALTER TABLE tasks ADD COLUMN list TEXT DEFAULT 'Reminders'");
      d.execSQL(
          "CREATE TABLE lists (name TEXT PRIMARY KEY,position INTEGER,selected INTEGER,color"
              + " INTEGER)");
      d.execSQL("INSERT INTO lists VALUES ('Reminders',0,1,-5206444)");
    }
  }

  List<CalendarRow> calendars() {
    var out = new ArrayList<CalendarRow>();
    try (var c = getReadableDatabase().rawQuery("SELECT * FROM calendars ORDER BY name", null)) {
      while (c.moveToNext())
        out.add(
            new CalendarRow(
                c.getString(0), c.getString(1), c.getInt(2), c.getInt(3) == 1, c.getInt(4) == 1));
    }
    return out;
  }

  void select(String id, boolean selected) {
    ContentValues v = new ContentValues();
    v.put("selected", selected ? 1 : 0);
    getWritableDatabase().update("calendars", v, "id=?", new String[] {id});
  }

  void replace(List<CalDav.CalendarInfo> calendars, Map<String, List<CalDav.Resource>> events) {
    var d = getWritableDatabase();
    d.beginTransaction();
    try {
      Map<String, Boolean> selected = new HashMap<>();
      for (var c : calendars()) selected.put(c.id, c.selected);
      d.delete("events", null, null);
      d.delete("calendars", null, null);
      for (var c : calendars) {
        ContentValues v = new ContentValues();
        v.put("id", c.url());
        v.put("name", c.name());
        int color = 0xff7899b0;
        try {
          String hex = c.color();
          if (hex.length() == 9) hex = hex.substring(0, 7);
          color = android.graphics.Color.parseColor(hex);
        } catch (Exception ignored) {
        }
        v.put("color", color);
        v.put("writable", c.writable());
        v.put("selected", selected.getOrDefault(c.url(), true));
        d.insertOrThrow("calendars", null, v);
        for (var e : events.getOrDefault(c.url(), List.of())) {
          v = new ContentValues();
          v.put("id", e.url());
          v.put("calendar", c.url());
          v.put("etag", e.etag());
          v.put("raw", e.text());
          d.insertOrThrow("events", null, v);
        }
      }
      d.setTransactionSuccessful();
    } finally {
      d.endTransaction();
    }
  }

  List<Item> items(long from, long to, boolean includeUndated, boolean completed) {
    List<Item> out = new ArrayList<>();
    if (to != Long.MAX_VALUE)
      try (var c =
          getReadableDatabase()
              .rawQuery(
                  "SELECT e.id,e.calendar,e.etag,e.raw,c.color FROM events e JOIN calendars c ON"
                      + " e.calendar=c.id WHERE c.selected=1",
                  null)) {
        while (c.moveToNext()) {
          try {
            for (var e : CalendarCodec.expand(c.getString(3), from, to))
              out.add(
                  new Item(
                      c.getString(0),
                      c.getString(1),
                      e.title(),
                      e.notes(),
                      e.location(),
                      e.start(),
                      e.end(),
                      e.allDay(),
                      false,
                      false,
                      e.recurring(),
                      c.getString(3),
                      c.getString(2),
                      c.getInt(4)));
          } catch (Exception ex) {
            throw new IllegalStateException(
                "Could not read a synced calendar event. Sync again.", ex);
          }
        }
      }
    try (var c =
        getReadableDatabase()
            .rawQuery(
                "SELECT tasks.* FROM tasks JOIN lists ON tasks.list=lists.name WHERE"
                    + " lists.selected=1 AND (?=1 OR done=0) AND ((due>=? AND due<?) OR (?=1 AND"
                    + " due=0))",
                new String[] {
                  completed ? "1" : "0", "" + from, "" + to, includeUndated ? "1" : "0"
                })) {
      while (c.moveToNext())
        out.add(
            new Item(
                c.getString(0),
                c.getString(5),
                c.getString(1),
                c.getString(2),
                "",
                c.getLong(3),
                c.getLong(3),
                false,
                true,
                c.getInt(4) == 1,
                false,
                "",
                "",
                0xffb08e54));
    }
    if (to != Long.MAX_VALUE
        && context.getSharedPreferences("settings", 0).getBoolean("contacts", false))
      out.addAll(
          ContactDates.occurrences(
              contactDates(),
              from,
              to,
              context.getSharedPreferences("settings", 0).getInt("contactColor", 0xff8e8e93)));
    out.sort(Comparator.comparingLong(Item::start));
    return out;
  }

  void task(String id, String title, String notes, long due, boolean done) {
    ContentValues v = new ContentValues();
    v.put("id", id);
    v.put("title", title);
    v.put("notes", notes);
    v.put("due", due);
    v.put("done", done);
    if (getWritableDatabase().update("tasks", v, "id=?", new String[] {id}) == 0)
      getWritableDatabase().insertOrThrow("tasks", null, v);
    TaskAlerts.schedule(context);
  }

  void removeTask(String id) {
    getWritableDatabase().delete("tasks", "id=?", new String[] {id});
    TaskAlerts.schedule(context);
  }

  void disconnect() {
    getWritableDatabase().delete("contact_dates", null, null);
    getWritableDatabase().delete("events", null, null);
    getWritableDatabase().delete("calendars", null, null);
  }

  record TaskList(String name, int order, boolean selected, int color) {}

  List<TaskList> lists() {
    List<TaskList> result = new ArrayList<>();
    try (var c =
        getReadableDatabase().rawQuery("SELECT * FROM lists ORDER BY position,name", null)) {
      while (c.moveToNext())
        result.add(new TaskList(c.getString(0), c.getInt(1), c.getInt(2) == 1, c.getInt(3)));
    }
    return result;
  }

  void addList(String name) {
    if (name.isBlank()) throw new IllegalArgumentException("Enter a list name.");
    ContentValues v = new ContentValues();
    v.put("name", name);
    v.put("position", lists().size());
    v.put("selected", 1);
    v.put("color", 0xffb08e54);
    getWritableDatabase().insertOrThrow("lists", null, v);
  }

  void listSelected(String name, boolean selected) {
    ContentValues v = new ContentValues();
    v.put("selected", selected);
    getWritableDatabase().update("lists", v, "name=?", new String[] {name});
  }

  void taskList(String id, String list) {
    ContentValues v = new ContentValues();
    v.put("list", list);
    getWritableDatabase().update("tasks", v, "id=?", new String[] {id});
  }

  void moveList(String name, int direction) {
    var lists = lists();
    int index = -1;
    for (int n = 0; n < lists.size(); n++) if (lists.get(n).name().equals(name)) index = n;
    int other = index + direction;
    if (index < 0 || other < 0 || other >= lists.size()) return;
    var d = getWritableDatabase();
    d.beginTransaction();
    try {
      Collections.swap(lists, index, other);
      for (int n = 0; n < lists.size(); n++) {
        ContentValues v = new ContentValues();
        v.put("position", n);
        d.update("lists", v, "name=?", new String[] {lists.get(n).name()});
      }
      d.setTransactionSuccessful();
    } finally {
      d.endTransaction();
    }
  }

  void contacts(List<ContactDates.DateRecord> records) {
    var d = getWritableDatabase();
    d.beginTransaction();
    try {
      d.delete("contact_dates", null, null);
      for (var r : records) {
        ContentValues v = new ContentValues();
        v.put("id", r.id());
        v.put("name", r.name());
        v.put("label", r.label());
        v.put("year", r.year());
        v.put("month", r.month());
        v.put("day", r.day());
        d.insertWithOnConflict("contact_dates", null, v, SQLiteDatabase.CONFLICT_REPLACE);
      }
      d.setTransactionSuccessful();
    } finally {
      d.endTransaction();
    }
  }

  List<ContactDates.DateRecord> contactDates() {
    List<ContactDates.DateRecord> result = new ArrayList<>();
    try (var c = getReadableDatabase().rawQuery("SELECT * FROM contact_dates", null)) {
      while (c.moveToNext())
        result.add(
            new ContactDates.DateRecord(
                c.getString(0),
                c.getString(1),
                c.getString(2),
                c.getInt(3),
                c.getInt(4),
                c.getInt(5)));
    }
    return result;
  }
}
