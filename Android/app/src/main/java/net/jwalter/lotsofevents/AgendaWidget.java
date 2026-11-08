package net.jwalter.lotsofevents;

import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.graphics.*;
import android.os.Bundle;
import android.view.View;
import android.widget.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;

public class AgendaWidget extends AppWidgetProvider {
  public static class ThreeDay extends AgendaWidget {}

  public static class Next extends AgendaWidget {}

  public static class Split extends AgendaWidget {}

  public static class Five extends AgendaWidget {}

  public static class Month extends AgendaWidget {}

  public static class Focus extends AgendaWidget {}

  public static class Open extends AgendaWidget {}

  public static class Tomorrow extends AgendaWidget {}

  public static class CatchUp extends AgendaWidget {}

  public static class Tasks extends AgendaWidget {}

  static final Class<?>[] TYPES = {
    AgendaWidget.class,
    ThreeDay.class,
    Next.class,
    Split.class,
    Five.class,
    Month.class,
    Focus.class,
    Open.class,
    Tomorrow.class,
    CatchUp.class,
    Tasks.class
  };

  static int kind(AppWidgetManager m, int id) {
    var info = m.getAppWidgetInfo(id);
    if (info != null)
      for (int k = 0; k < TYPES.length; k++)
        if (info.provider.getClassName().equals(TYPES[k].getName())) return k;
    return 0;
  }

  static android.content.SharedPreferences prefs(Context c, int id) {
    return c.getSharedPreferences("widget_" + id, 0);
  }

  public void onReceive(Context c, Intent i) {
    super.onReceive(c, i);
    if (Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())) {
      SyncJob.schedule(c);
      TaskAlerts.schedule(c);
      refresh(c);
      return;
    }
    if (!"net.jwalter.lotsofevents.WIDGET".equals(i.getAction())) return;
    int id = i.getIntExtra("widget", 0);
    var p = prefs(c, id);
    String action = i.getStringExtra("action");
    if ("day".equals(action)) {
      p.edit()
          .putLong("selected", i.getLongExtra("day", 0))
          .putLong("interacted", System.currentTimeMillis())
          .apply();
      int reset = p.getInt("reset", 30);
      if (reset > 0) {
        var alarm = c.getSystemService(AlarmManager.class);
        alarm.set(
            AlarmManager.RTC,
            System.currentTimeMillis() + reset * 1000L,
            command(c, id, "reset", 0));
      }
    }
    if ("reset".equals(action)) {
      int reset = p.getInt("reset", 30);
      if (reset > 0 && System.currentTimeMillis() - p.getLong("interacted", 0) >= reset * 1000L)
        p.edit().remove("selected").apply();
    }
    if ("complete".equals(action)) {
      String task = i.getStringExtra("task");
      try (Store s = new Store(c)) {
        for (var item : s.items(0, Long.MAX_VALUE, true, false))
          if (item.id().equals(task)) {
            s.task(item.id(), item.title(), item.notes(), item.start(), true);
            p.edit().putString("undo", task).putLong("undoAt", System.currentTimeMillis()).apply();
            break;
          }
      }
    }
    if ("undo".equals(action) && System.currentTimeMillis() - p.getLong("undoAt", 0) < 30000) {
      try (Store s = new Store(c)) {
        for (var item : s.items(0, Long.MAX_VALUE, true, true))
          if (item.id().equals(p.getString("undo", "")))
            s.task(item.id(), item.title(), item.notes(), item.start(), false);
      }
      p.edit().remove("undo").apply();
    }
    if ("open".equals(action))
      c.startActivity(
          new Intent(c, MainActivity.class)
              .putExtra("item", i.getStringExtra("item"))
              .putExtra("itemStart", i.getLongExtra("itemStart", 0))
              .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP));
    refresh(c);
  }

  public void onUpdate(Context c, AppWidgetManager m, int[] ids) {
    for (int id : ids) update(c, m, id);
  }

  public void onAppWidgetOptionsChanged(Context c, AppWidgetManager m, int id, Bundle options) {
    update(c, m, id);
  }

  public void onDeleted(Context c, int[] ids) {
    for (int id : ids) prefs(c, id).edit().clear().apply();
  }

  static void refresh(Context c) {
    var m = AppWidgetManager.getInstance(c);
    for (var type : TYPES)
      for (int id : m.getAppWidgetIds(new ComponentName(c, type))) update(c, m, id);
  }

  static PendingIntent command(Context c, int id, String action, long day) {
    Intent i =
        new Intent(c, TYPES[kind(AppWidgetManager.getInstance(c), id)])
            .setAction("net.jwalter.lotsofevents.WIDGET")
            .setData(android.net.Uri.parse("loe://widget/" + id + "/" + action + "/" + day))
            .putExtra("widget", id)
            .putExtra("action", action)
            .putExtra("day", day);
    return PendingIntent.getBroadcast(
        c, 0, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
  }

  static void update(Context c, AppWidgetManager m, int id) {
    int kind = kind(m, id);
    var p = prefs(c, id);
    var app = c.getSharedPreferences("settings", 0);
    int[] palette = Palette.widget(c, p.getInt("theme", app.getInt("widgetTheme", 0)));
    int size = p.getInt("size", 14), spacing = p.getInt("spacing", 2);
    boolean times = p.getBoolean("times", true);
    boolean taskEnabled = p.getBoolean("tasks", true);
    int days = kind == 3 && !p.getBoolean("upcoming", false) ? 1 : app.getInt("days", 5);
    LocalDate today = LocalDate.now(),
        selected = LocalDate.ofEpochDay(p.getLong("selected", today.toEpochDay()));
    int timeout = p.getInt("reset", 30);
    if (timeout > 0 && System.currentTimeMillis() - p.getLong("interacted", 0) > timeout * 1000L)
      selected = today;
    RemoteViews view = new RemoteViews(c.getPackageName(), R.layout.widget);
    view.setTextViewText(
        R.id.widget_title,
        kind == 5
            ? selected.format(DateTimeFormatter.ofPattern("MMMM yyyy"))
            : WidgetData.NAMES[kind]);
    view.setTextColor(R.id.widget_title, palette[1]);
    view.setTextColor(R.id.widget_settings, palette[3]);
    view.setTextColor(R.id.widget_add, palette[3]);
    view.setTextColor(R.id.widget_empty, palette[2]);
    view.setViewVisibility(R.id.widget_add, p.getBoolean("add", true) ? View.VISIBLE : View.GONE);
    Bitmap bg = Bitmap.createBitmap(200, 200, Bitmap.Config.ARGB_8888);
    Canvas canvas = new Canvas(bg);
    Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    int end = p.getInt("gradient", palette[0]);
    paint.setShader(new LinearGradient(0, 0, 0, 200, palette[0], end, Shader.TileMode.CLAMP));
    canvas.drawRoundRect(0, 0, 200, 200, 22, 22, paint);
    view.setImageViewBitmap(R.id.widget_bg, bg);
    Intent open =
        new Intent(c, MainActivity.class)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
    view.setOnClickPendingIntent(
        R.id.widget_title,
        PendingIntent.getActivity(
            c, id, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
    view.setOnClickPendingIntent(
        R.id.widget_add,
        PendingIntent.getActivity(
            c,
            10000 + id,
            new Intent(c, MainActivity.class)
                .putExtra("add", true)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
    view.setOnClickPendingIntent(
        R.id.widget_settings,
        PendingIntent.getActivity(
            c,
            20000 + id,
            new Intent(c, WidgetOptions.class).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
    view.removeAllViews(R.id.widget_days);
    if (kind == 1 || kind == 4) dayRow(c, view, id, kind == 1 ? 3 : 5, today, selected, palette);
    if (kind == 5) {
      LocalDate first = selected.withDayOfMonth(1);
      first = first.minusDays(first.getDayOfWeek().getValue() % 7);
      for (int r = 0; r < 6; r++) dayRow(c, view, id, 7, first.plusDays(r * 7), selected, palette);
    }
    var collection =
        new RemoteViews.RemoteCollectionItems.Builder().setHasStableIds(false).setViewTypeCount(1);
    int n = 0;
    try (Store store = new Store(c)) {
      List<Store.Item> items =
          new ArrayList<>(
              store.items(
                  WidgetData.start(kind == 5 ? selected.withDayOfMonth(1) : today.minusDays(1)),
                  WidgetData.start(
                      kind == 5
                          ? selected.withDayOfMonth(1).plusMonths(1)
                          : today.plusDays(kind == 2 ? 14 : Math.max(days, 5))),
                  false,
                  false));
      items.removeIf(Store.Item::task);
      items.addAll(store.items(0, Long.MAX_VALUE, true, false));
      Set<String> sources = p.getStringSet("sources", null);
      Set<String> taskLists = p.getStringSet("taskLists", null);
      items.removeIf(i -> i.task() && taskLists != null && !taskLists.contains(i.calendar()));
      items.removeIf(
          i ->
              i.task() && !taskEnabled
                  || !i.task() && sources != null && !sources.contains(i.calendar()));
      items.sort(Comparator.comparingLong(Store.Item::start));
      List<WidgetData.Line> lines =
          WidgetData.build(
              kind,
              items,
              selected,
              days,
              times,
              p.getInt("startHour", 9),
              p.getInt("endHour", 17));
      for (var line : lines) {
        if (n >= 200) break;
        var item = line.item();
        RemoteViews row = new RemoteViews(c.getPackageName(), R.layout.widget_row);
        row.setTextViewText(R.id.row_title, font(line.title(), p.getString("font", "sans-serif")));
        row.setTextViewTextSize(
            R.id.row_title,
            android.util.TypedValue.COMPLEX_UNIT_SP,
            line.heading() ? Math.max(10, size - 2) : size);
        row.setTextColor(R.id.row_title, line.heading() ? palette[2] : palette[1]);
        row.setTextViewText(R.id.row_time, line.subtitle());
        row.setTextColor(R.id.row_time, palette[2]);
        row.setViewVisibility(R.id.row_time, line.subtitle().isEmpty() ? View.GONE : View.VISIBLE);
        row.setViewVisibility(
            R.id.row_bar,
            item != null && !item.task() && p.getBoolean("bars", true) ? View.VISIBLE : View.GONE);
        row.setViewVisibility(
            R.id.row_check, item != null && item.task() ? View.VISIBLE : View.GONE);
        if (item != null) {
          row.setInt(R.id.row_bar, "setBackgroundColor", item.color());
          row.setTextColor(R.id.row_check, item.color());
          row.setOnClickFillInIntent(
              R.id.row,
              new Intent()
                  .putExtra("action", "open")
                  .putExtra("item", item.id())
                  .putExtra("itemStart", item.start()));
          if (item.task())
            row.setOnClickFillInIntent(
                R.id.row_check,
                new Intent().putExtra("action", "complete").putExtra("task", item.id()));
        }
        row.setViewPadding(R.id.row, 0, spacing, 0, spacing);
        collection.addItem(n++, row);
      }
    } catch (Exception e) {
      view.setTextViewText(R.id.widget_empty, "Open LotsOfEvents to refresh your agenda.");
    }
    view.setRemoteAdapter(R.id.widget_list, collection.build());
    view.setEmptyView(R.id.widget_list, R.id.widget_empty);
    Intent actions =
        new Intent(c, TYPES[kind])
            .setAction("net.jwalter.lotsofevents.WIDGET")
            .setData(android.net.Uri.parse("loe://items/" + id))
            .putExtra("widget", id);
    view.setPendingIntentTemplate(
        R.id.widget_list,
        PendingIntent.getBroadcast(
            c, id, actions, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE));
    boolean undo =
        p.contains("undo") && System.currentTimeMillis() - p.getLong("undoAt", 0) < 30000;
    view.setViewVisibility(R.id.widget_undo, undo ? View.VISIBLE : View.GONE);
    view.setTextColor(R.id.widget_undo, palette[3]);
    view.setOnClickPendingIntent(R.id.widget_undo, command(c, id, "undo", 0));
    m.updateAppWidget(id, view);
  }

  private static CharSequence font(String s, String family) {
    var text = new android.text.SpannableString(s);
    text.setSpan(new android.text.style.TypefaceSpan(family), 0, text.length(), 0);
    return text;
  }

  private static void dayRow(
      Context c,
      RemoteViews root,
      int id,
      int count,
      LocalDate first,
      LocalDate selected,
      int[] colors) {
    RemoteViews row =
        new RemoteViews(
            c.getPackageName(),
            count == 3
                ? R.layout.widget_days3
                : count == 5 ? R.layout.widget_days5 : R.layout.widget_days7);
    int[] ids = {R.id.day0, R.id.day1, R.id.day2, R.id.day3, R.id.day4, R.id.day5, R.id.day6};
    for (int j = 0; j < count; j++) {
      LocalDate d = first.plusDays(j);
      row.setTextViewText(
          ids[j],
          count == 7 ? "" + d.getDayOfMonth() : d.format(DateTimeFormatter.ofPattern("EEE\nd")));
      row.setTextColor(ids[j], d.equals(selected) ? Color.BLACK : colors[3]);
      row.setInt(ids[j], "setBackgroundColor", d.equals(selected) ? colors[3] : Color.TRANSPARENT);
      row.setOnClickPendingIntent(ids[j], command(c, id, "day", d.toEpochDay()));
    }
    root.addView(R.id.widget_days, row);
  }
}
