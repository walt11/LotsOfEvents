package net.jwalter.lotsofevents;

import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.os.*;
import android.widget.*;
import java.util.*;

public class WidgetOptions extends Activity {
  private int id;
  private android.content.SharedPreferences prefs;
  private LinearLayout form;

  public void onCreate(Bundle state) {
    super.onCreate(state);
    id =
        getIntent()
            .getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID);
    setResult(RESULT_CANCELED);
    if (id == AppWidgetManager.INVALID_APPWIDGET_ID) {
      finish();
      return;
    }
    prefs = AgendaWidget.prefs(this, id);
    form = new LinearLayout(this);
    form.setOrientation(LinearLayout.VERTICAL);
    form.setPadding(32, 40, 32, 32);
    ScrollView scroll = new ScrollView(this);
    scroll.addView(form);
    setContentView(scroll);
    int kind = AgendaWidget.kind(AppWidgetManager.getInstance(this), id);
    label(WidgetData.NAMES[kind] + " options", 24);
    select("Theme", Palette.WIDGETS, "theme", 0);
    select("Text size", new String[] {"Small", "Standard", "Large", "Extra large"}, "sizeIndex", 1);
    select("Font", new String[] {"Default", "Rounded", "Serif", "Monospaced"}, "fontIndex", 0);
    select("Spacing", new String[] {"Compact", "Standard", "Roomy"}, "spacingIndex", 1);
    select(
        "Return to today after",
        new String[] {"Off", "30 seconds", "1 minute", "5 minutes"},
        "resetIndex",
        1);
    toggle("Show times", "times", true);
    toggle("Show calendar color bars", "bars", true);
    toggle("Show + button", "add", true);
    toggle("Include tasks from this device", "tasks", true);
    if (kind == 3) toggle("Include Upcoming Days (uses app Days Ahead)", "upcoming", false);
    label("Calendars", 18);
    try (Store store = new Store(this)) {
      Set<String> saved = prefs.getStringSet("sources", null);
      Set<String> allIds =
          new HashSet<>(
              store.calendars().stream()
                  .map(Store.CalendarRow::id)
                  .collect(java.util.stream.Collectors.toList()));
      for (var c : store.calendars()) {
        CheckBox b = new CheckBox(this);
        b.setText(c.name());
        b.setChecked(saved == null || saved.contains(c.id()));
        b.setOnCheckedChangeListener(
            (v, on) -> {
              Set<String> ids = new HashSet<>(prefs.getStringSet("sources", allIds));
              if (on) ids.add(c.id());
              else ids.remove(c.id());
              prefs.edit().putStringSet("sources", ids).apply();
            });
        form.addView(b);
      }
    }
    label("Reminder lists on this device", 18);
    try (Store store = new Store(this)) {
      var allLists = store.lists();
      Set<String> allNames = new HashSet<>();
      for (var list : allLists) allNames.add(list.name());
      Set<String> saved = prefs.getStringSet("taskLists", null);
      for (var list : allLists) {
        CheckBox checkbox = new CheckBox(this);
        checkbox.setText(list.name());
        checkbox.setChecked(saved == null || saved.contains(list.name()));
        checkbox.setOnCheckedChangeListener(
            (v, on) -> {
              Set<String> names = new HashSet<>(prefs.getStringSet("taskLists", allNames));
              if (on) names.add(list.name());
              else names.remove(list.name());
              prefs.edit().putStringSet("taskLists", names).apply();
            });
        form.addView(checkbox);
      }
    }
    if (kind == 7) {
      select(
          "Working day starts",
          new String[] {"6 AM", "7 AM", "8 AM", "9 AM", "10 AM"},
          "workStart",
          3);
      select(
          "Working day ends",
          new String[] {"3 PM", "4 PM", "5 PM", "6 PM", "7 PM", "8 PM"},
          "workEnd",
          2);
    }
    label(
        "Scroll the widget’s list to see more items. Day selections return to today after the"
            + " chosen time when Android permits the update.",
        14);
    Button save = new Button(this);
    save.setText("Save widget");
    save.setOnClickListener(
        v -> {
          int[] sizes = {12, 14, 16, 18}, spacing = {0, 2, 5}, reset = {0, 30, 60, 300};
          String[] fonts = {"sans-serif", "sans-serif-rounded", "serif", "monospace"};
          prefs
              .edit()
              .putInt("size", sizes[prefs.getInt("sizeIndex", 1)])
              .putInt("spacing", spacing[prefs.getInt("spacingIndex", 1)])
              .putInt("reset", reset[prefs.getInt("resetIndex", 1)])
              .putString("font", fonts[prefs.getInt("fontIndex", 0)])
              .putInt("startHour", prefs.getInt("workStart", 3) + 6)
              .putInt("endHour", prefs.getInt("workEnd", 2) + 15)
              .apply();
          AgendaWidget.update(this, AppWidgetManager.getInstance(this), id);
          setResult(RESULT_OK, new Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id));
          finish();
        });
    form.addView(save);
  }

  private void label(String s, int size) {
    TextView t = new TextView(this);
    t.setText(s);
    t.setTextSize(size);
    t.setPadding(0, 16, 0, 8);
    form.addView(t);
  }

  private void toggle(String title, String key, boolean value) {
    Switch s = new Switch(this);
    s.setText(title);
    s.setPadding(0, 14, 0, 14);
    s.setChecked(prefs.getBoolean(key, value));
    s.setOnCheckedChangeListener((v, on) -> prefs.edit().putBoolean(key, on).apply());
    form.addView(s);
  }

  private void select(String title, String[] values, String key, int def) {
    label(title, 14);
    Spinner s = new Spinner(this);
    s.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, values));
    s.setSelection(prefs.getInt(key, def));
    s.setOnItemSelectedListener(
        new AdapterView.OnItemSelectedListener() {
          public void onNothingSelected(AdapterView<?> v) {}

          public void onItemSelected(AdapterView<?> v, android.view.View row, int p, long id) {
            prefs.edit().putInt(key, p).apply();
          }
        });
    form.addView(s);
  }
}
