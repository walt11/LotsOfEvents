package net.jwalter.lotsofevents;

import android.app.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;

public class MainActivity extends Activity {
  private LinearLayout root, body, nav;
  private Store store;
  private int tab = 0;
  private LocalDate selected = LocalDate.now();
  private YearMonth month = YearMonth.now();
  private int agendaDays = 30;
  private boolean busy = false;
  private String search = "";
  private String settingsPage = "";
  private int calendarMode = 0;
  private boolean showSearch = false;
  private final ExecutorService executor = Executors.newSingleThreadExecutor();
  private int paper, card, ink, muted, accent = 0xff648da9;

  private android.content.SharedPreferences prefs() {
    return getSharedPreferences("settings", 0);
  }

  private int dp(int n) {
    return Math.round(n * getResources().getDisplayMetrics().density);
  }

  @Override
  public void onCreate(Bundle b) {
    super.onCreate(b);
    store = new Store(this);
    SyncJob.schedule(this);
    selectScreen(getIntent());
    render();
    if (getIntent().getBooleanExtra("add", false)) quickAdd();
    else openFromWidget(getIntent());
  }

  @Override
  public void onNewIntent(Intent i) {
    super.onNewIntent(i);
    selectScreen(i);
    if (i.getBooleanExtra("add", false)) quickAdd();
    else {
      render();
      openFromWidget(i);
    }
  }

  private void selectScreen(Intent intent) {
    String screen=intent.getStringExtra("screen");
    if(screen==null)return;
    switch(screen){case "agenda":tab=0;break;case "calendar":tab=1;break;case "reminders":tab=2;break;case "settings":tab=3;settingsPage="";break;default:break;}
  }

  private LinearLayout column() {
    LinearLayout l = new LinearLayout(this);
    l.setOrientation(LinearLayout.VERTICAL);
    return l;
  }

  private TextView text(String value, int size, int color) {
    TextView t = new TextView(this);
    t.setText(value);
    t.setTextSize(size);
    t.setTextColor(color);
    t.setPadding(dp(4), dp(5), dp(4), dp(5));
    return t;
  }

  private void rounded(View v, int color) {
    GradientDrawable d = new GradientDrawable();
    d.setColor(color);
    d.setCornerRadius(dp(16));
    v.setBackground(d);
  }

  private Button button(String label, Runnable action) {
    Button b = new Button(this);
    b.setText(label);
    b.setTextColor(accent);
    b.setAllCaps(false);
    b.setMinHeight(dp(44));
    b.setOnClickListener(v -> action.run());
    return b;
  }

  private void title(String s) {
    LinearLayout header = row();
    TextView t = text(s, 24, ink);
    t.setTypeface(null, Typeface.BOLD);
    header.addView(t, new LinearLayout.LayoutParams(0, -2, 1));
    if (tab != 3) {
      header.addView(
          button(
              "Today",
              () -> {
                selected = LocalDate.now();
                month = YearMonth.now();
                agendaDays = 30;
                render();
              }));
      header.addView(
          button(
              "⌕",
              () -> {
                showSearch = !showSearch;
                render();
              }));
    }
    body.addView(header);
  }

  private LinearLayout row() {
    LinearLayout l = new LinearLayout(this);
    l.setGravity(Gravity.CENTER_VERTICAL);
    return l;
  }

  private void render() {
    int[] colors = Palette.app(this);
    paper = colors[0];
    card = colors[1];
    ink = colors[2];
    muted = colors[3];
    accent = colors[4];
    boolean dark = Color.luminance(paper) < 0.3;
    setTheme(
        dark
            ? android.R.style.Theme_Material_NoActionBar
            : android.R.style.Theme_Material_Light_NoActionBar);
    root = column();
    root.setBackgroundColor(paper);
    root.setPadding(dp(16), dp(8), dp(16), 0);
    root.setOnApplyWindowInsetsListener(
        (v, insets) -> {
          var bars = insets.getInsets(WindowInsets.Type.systemBars());
          v.setPadding(dp(16), bars.top + dp(8), dp(16), bars.bottom);
          return insets;
        });
    setContentView(root);
    getWindow()
        .getInsetsController()
        .setSystemBarsAppearance(
            dark ? 0 : WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS);

    ScrollView scroll = new ScrollView(this);
    scroll.setFillViewport(true);
    body = column();
    scroll.addView(body);
    root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    if (tab == 0) agenda();
    else if (tab == 1) calendar();
    else if (tab == 2) tasks();
    else settings();
    nav = row();
    rounded(nav, card);
    String[] labels = {"▤\nAgenda", "▦\nCalendar", "+", "☑\nReminders", "⚙\nSettings"};
    for (int i = 0; i < 5; i++) {
      int n = i > 2 ? i - 1 : i;
      int position = i;
      Button button =
          button(
              labels[i],
              () -> {
                if (position == 2) {
                  quickAdd();
                  return;
                }
                if (tab == n) {
                  selected = LocalDate.now();
                  month = YearMonth.now();
                  agendaDays = 30;
                }
                tab = n;
                settingsPage = "";
                render();
              });
      button.setBackgroundColor(Color.TRANSPARENT);
      button.setTextSize(i == 2 ? 32 : 11);
      button.setPadding(0, 0, 0, 0);
      if (tab == n && i != 2) button.setTypeface(null, Typeface.BOLD);
      nav.addView(button, new LinearLayout.LayoutParams(0, dp(60), 1));
    }
    root.addView(nav);
  }

  private long midnight(LocalDate d) {
    return d.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli();
  }

  private void tools() {
    if (tab == 1) {
      LinearLayout r = row();
      r.addView(
          button(
              new String[] {"Month ▾", "Day ▾", "3 Days ▾", "Week ▾", "Year ▾"}[calendarMode],
              () ->
                  new AlertDialog.Builder(this)
                      .setItems(
                          new String[] {"Month", "Day", "3 Days", "Week", "Year"},
                          (d, n) -> {
                            calendarMode = n;
                            render();
                          })
                      .show()),
          new LinearLayout.LayoutParams(0, -2, 1));
      r.addView(button("Weekly Planner", () -> weeklyPlanner()));
      body.addView(r);
    }
    if (showSearch) {
      EditText find = new EditText(this);
      find.setSingleLine();
      find.setTextColor(ink);
      find.setHint("Search events and reminders");
      find.setText(search);
      body.addView(find);
      body.addView(
          button(
              "Search",
              () -> {
                search = find.getText().toString();
                tab = 0;
                render();
              }));
    }
  }

  private void agenda() {
    title("Agenda");
    tools();

    List<Store.Item> items =
        read(
            midnight(LocalDate.now()), midnight(LocalDate.now().plusDays(agendaDays)), true, false);
    LocalDate last = null;
    for (var item : items) {
      if (!item.title()
              .toLowerCase(Locale.getDefault())
              .contains(search.toLowerCase(Locale.getDefault()))
          && !item.notes()
              .toLowerCase(Locale.getDefault())
              .contains(search.toLowerCase(Locale.getDefault()))) continue;
      if (!prefs().getBoolean("past", true)
          && !item.task()
          && item.end() < System.currentTimeMillis()) continue;
      LocalDate d =
          item.start() == 0
              ? null
              : Instant.ofEpochMilli(item.start()).atZone(ZoneId.systemDefault()).toLocalDate();
      if (!Objects.equals(d, last) || last == null) {
        body.addView(
            text(
                d == null
                    ? "UNDATED TASKS"
                    : d.format(DateTimeFormatter.ofPattern("EEE, MMM d"))
                        .toUpperCase(Locale.getDefault()),
                13,
                muted));
        last = d;
      }
      item(item);
    }
    if (items.isEmpty()) empty();
    body.addView(
        button(
            "Show another 30 days",
            () -> {
              agendaDays += 30;
              render();
            }));
    body.addView(text("Calendar sync covers the previous year and next two years.", 12, muted));
  }

  private void empty() {
    body.addView(text("Nothing scheduled", 20, ink));
    body.addView(text("Connect iCloud in Settings or add a local task to get started.", 14, muted));
  }

  private List<Store.Item> read(long from, long to, boolean undated, boolean completed) {
    try {
      return store.items(from, to, undated, completed);
    } catch (Exception e) {
      body.addView(text(e.getMessage(), 14, muted));
      return List.of();
    }
  }

  private void calendar() {
    title("Calendar");
    tools();
    if (calendarMode != 0) {
      alternateCalendar();
      return;
    }
    LinearLayout header = row();
    header.addView(
        button(
            "‹",
            () -> {
              month = month.minusMonths(1);
              render();
            }));
    TextView name = text(month.format(DateTimeFormatter.ofPattern("MMMM yyyy")), 21, ink);
    name.setGravity(Gravity.CENTER);
    header.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
    header.addView(
        button(
            "›",
            () -> {
              month = month.plusMonths(1);
              render();
            }));
    body.addView(header);
    LinearLayout week = row();
    for (String w : new String[] {"S", "M", "T", "W", "T", "F", "S"}) {
      TextView t = text(w, 12, muted);
      t.setGravity(Gravity.CENTER);
      week.addView(t, new LinearLayout.LayoutParams(0, -2, 1));
    }
    body.addView(week);
    LocalDate first = month.atDay(1).minusDays(month.atDay(1).getDayOfWeek().getValue() % 7);
    Set<LocalDate> occupied = new HashSet<>();
    for (var i : read(midnight(first), midnight(first.plusDays(42)), false, false))
      occupied.add(Instant.ofEpochMilli(i.start()).atZone(ZoneId.systemDefault()).toLocalDate());
    SwipeLayout grid =
        new SwipeLayout(
            this,
            direction -> {
              month = month.plusMonths(direction);
              render();
            });
    body.addView(grid);
    for (int r = 0; r < 6; r++) {
      LinearLayout line = row();
      for (int c = 0; c < 7; c++) {
        LocalDate d = first.plusDays(r * 7 + c);
        Button day =
            button(
                "" + d.getDayOfMonth() + (occupied.contains(d) ? "\n•" : ""),
                () -> {
                  selected = d;
                  render();
                });
        day.setTextSize(14);
        day.setPadding(0, 0, 0, 0);
        day.setTextColor(YearMonth.from(d).equals(month) ? ink : muted);
        day.setBackgroundColor(Color.TRANSPARENT);
        if (c == 0 || c == 6) rounded(day, card);
        if (d.equals(selected)) rounded(day, accent);
        line.addView(day, new LinearLayout.LayoutParams(0, dp(52), 1));
      }
      grid.addView(line);
    }
    LinearLayout dayHeader = row();
    dayHeader.addView(
        button(
            "‹",
            () -> {
              selected = selected.minusDays(1);
              month = YearMonth.from(selected);
              render();
            }));
    TextView label = text(selected.format(DateTimeFormatter.ofPattern("EEEE, MMM d")), 17, ink);
    dayHeader.addView(label, new LinearLayout.LayoutParams(0, -2, 1));
    dayHeader.addView(
        button(
            "›",
            () -> {
              selected = selected.plusDays(1);
              month = YearMonth.from(selected);
              render();
            }));
    body.addView(dayHeader);
    SwipeLayout pane =
        new SwipeLayout(
            this,
            direction -> {
              selected = selected.plusDays(direction);
              month = YearMonth.from(selected);
              render();
            });
    body.addView(pane);
    LinearLayout mainBody = body;
    body = pane;
    var items = read(midnight(selected), midnight(selected.plusDays(1)), false, false);
    for (var i : items) item(i);
    if (items.isEmpty()) body.addView(text("Nothing scheduled", 16, muted));
    body = mainBody;
  }

  private void tasks() {
    title("Reminders");
    body.addView(text("On this device · iCloud Reminders unavailable via app password", 12, muted));
    LinearLayout controls = row();
    controls.addView(
        button("+ Reminder", () -> editor(null, true)), new LinearLayout.LayoutParams(0, -2, 1));
    controls.addView(button("+ List", () -> newList()), new LinearLayout.LayoutParams(0, -2, 1));
    body.addView(controls);
    var tasks = store.items(0, Long.MAX_VALUE, true, true);
    for (var list : store.lists()) {
      LinearLayout head = row();
      head.addView(text(list.name(), 19, ink), new LinearLayout.LayoutParams(0, -2, 1));
      head.addView(
          button(
              "↑",
              () -> {
                store.moveList(list.name(), -1);
                render();
              }));
      head.addView(
          button(
              "↓",
              () -> {
                store.moveList(list.name(), 1);
                render();
              }));
      body.addView(head);
      for (var i : tasks) if (i.calendar().equals(list.name())) item(i);
    }
  }

  private void newList() {
    EditText name = new EditText(this);
    name.setHint("List name");
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("New local list")
            .setView(name)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Create", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      try {
                        store.addList(name.getText().toString().trim());
                        dialog.dismiss();
                        render();
                      } catch (Exception e) {
                        name.setError("Use a unique, nonempty list name");
                      }
                    }));
    dialog.show();
  }

  private void item(Store.Item i) {
    LinearLayout box = column();
    rounded(box, card);
    box.setPadding(dp(9), dp(4), dp(9), dp(4));
    LinearLayout line = row();
    if (i.task()) {
      CheckBox check = new CheckBox(this);
      check.setChecked(i.done());
      check.setContentDescription("Complete " + i.title());
      check.setOnCheckedChangeListener(
          (b, on) -> {
            store.task(i.id(), i.title(), i.notes(), i.start(), on);
            AgendaWidget.refresh(this);
          });
      line.addView(check);
    }
    TextView t = text(i.title(), i.calendar().equals("contacts") ? 13 : 17, i.done() ? muted : ink);
    t.setCompoundDrawablePadding(dp(5));
    line.addView(t, new LinearLayout.LayoutParams(0, -2, 1));
    box.addView(line);
    String timing =
        i.start() == 0
            ? "No due date"
            : i.allDay()
                ? ""
                : Instant.ofEpochMilli(i.start())
                    .atZone(ZoneId.systemDefault())
                    .format(DateTimeFormatter.ofPattern("h:mm a"));
    String detail = timing + (i.location().isBlank() ? "" : " · " + i.location());
    if (!detail.isBlank()) box.addView(text(detail, 13, muted));
    View bar = new View(this);
    bar.setBackgroundColor(i.color());
    line.addView(bar, 0, new LinearLayout.LayoutParams(dp(3), dp(34)));
    box.setOnClickListener(v -> details(i));
    LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2);
    p.bottomMargin = dp(6);
    body.addView(box, p);
  }

  private void details(Store.Item i) {
    String message =
        (i.start() == 0
                ? "No due date"
                : Instant.ofEpochMilli(i.start())
                    .atZone(ZoneId.systemDefault())
                    .format(DateTimeFormatter.ofPattern("EEE, MMM d, yyyy")))
            + "\n"
            + i.location()
            + "\n"
            + i.notes();
    AlertDialog.Builder b =
        new AlertDialog.Builder(this)
            .setTitle(i.title())
            .setMessage(message)
            .setNegativeButton("Close", null);
    boolean writable =
        i.task()
            || store.calendars().stream()
                .anyMatch(c -> c.id().equals(i.calendar()) && c.writable());
    if (writable && !i.recurring()) {
      b.setPositiveButton("Edit", (d, w) -> editor(i, i.task()));
      b.setNeutralButton(
          "Delete",
          (d, w) ->
              new AlertDialog.Builder(this)
                  .setMessage(
                      "Delete this "
                          + (i.task()
                              ? "local task?"
                              : "event from iCloud and your other devices?"))
                  .setNegativeButton("Cancel", null)
                  .setPositiveButton(
                      "Delete",
                      (x, y) -> {
                        if (i.task()) {
                          store.removeTask(i.id());
                          render();
                          AgendaWidget.refresh(this);
                        } else
                          work(
                              () -> {
                                String[] a = new Vault(this).read();
                                new CalDav(a[0], a[1]).delete(i.id(), i.etag());
                                Sync.run(this);
                              });
                      })
                  .show());
    }
    if (i.recurring())
      b.setMessage(
          message
              + "\n\n"
              + "Recurring event. Edit the series or individual occurrences in Apple Calendar.");
    b.show();
  }

  private EditText input(LinearLayout form, String hint, String value) {
    EditText e = new EditText(this);
    e.setHint(hint);
    e.setText(value);
    e.setTextColor(ink);
    form.addView(e);
    return e;
  }

  private void editor(Store.Item existing, boolean task) {
    LinearLayout form = column();
    form.setPadding(dp(20), dp(8), dp(20), dp(8));
    EditText title = input(form, "Title", existing == null ? draftTitle : existing.title()),
        location = input(form, "Location", existing == null ? "" : existing.location()),
        notes = input(form, "Notes", existing == null ? "" : existing.notes());
    location.setVisibility(task ? View.GONE : View.VISIBLE);
    draftTitle = "";
    long initial =
        existing != null && existing.start() > 0
            ? existing.start()
            : draftStart > 0 ? draftStart : midnight(selected) + 9 * 3600000L;
    draftStart = 0;
    final ZonedDateTime[] date = {Instant.ofEpochMilli(initial).atZone(ZoneId.systemDefault())};
    final ZonedDateTime[] end = {
      Instant.ofEpochMilli(existing == null ? initial + 3600000 : existing.end())
          .atZone(ZoneId.systemDefault())
    };
    if (existing != null && existing.allDay()) end[0] = end[0].minusDays(1);
    CheckBox due = new CheckBox(this);
    due.setText(task ? "Has due date" : "All day");
    due.setChecked(
        task ? existing != null && existing.start() > 0 : existing != null && existing.allDay());
    form.addView(due);
    Button startButton = button("", () -> {}), endButton = button("", () -> {});
    Runnable labels =
        () -> {
          startButton.setText(
              (task ? "Due: " : "Start: ")
                  + date[0].format(DateTimeFormatter.ofPattern("MMM d, yyyy · h:mm a")));
          endButton.setText(
              "End: " + end[0].format(DateTimeFormatter.ofPattern("MMM d, yyyy · h:mm a")));
          startButton.setVisibility(task && !due.isChecked() ? View.GONE : View.VISIBLE);
        };
    labels.run();
    due.setOnCheckedChangeListener((b, on) -> labels.run());
    startButton.setOnClickListener(v -> pickDate(date, labels, !task && due.isChecked()));
    endButton.setOnClickListener(v -> pickDate(end, labels, due.isChecked()));
    form.addView(startButton);
    if (!task) form.addView(endButton);
    Spinner lists = new Spinner(this);
    var taskLists = store.lists();
    if (task) {
      lists.setAdapter(
          new ArrayAdapter<>(
              this,
              android.R.layout.simple_spinner_dropdown_item,
              taskLists.stream().map(Store.TaskList::name).toArray(String[]::new)));
      form.addView(lists);
      if (existing != null)
        for (int n = 0; n < taskLists.size(); n++)
          if (taskLists.get(n).name().equals(existing.calendar())) lists.setSelection(n);
    }
    Spinner calendars = new Spinner(this);
    var writable =
        store.calendars().stream()
            .filter(Store.CalendarRow::writable)
            .collect(java.util.stream.Collectors.toList());
    if (!task) {
      calendars.setAdapter(
          new ArrayAdapter<>(
              this,
              android.R.layout.simple_spinner_dropdown_item,
              writable.stream().map(Store.CalendarRow::name).toArray(String[]::new)));
      form.addView(calendars);
      if (existing != null) {
        for (int j = 0; j < writable.size(); j++)
          if (writable.get(j).id().equals(existing.calendar())) calendars.setSelection(j);
        calendars.setEnabled(false);
      }
    }
    ScrollView scroll = new ScrollView(this);
    scroll.addView(form);
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle(task ? "Local task" : "iCloud event")
            .setView(scroll)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Save", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      String name = title.getText().toString().trim();
                      if (name.isBlank()) {
                        title.setError("Enter a title");
                        return;
                      }
                      long s = date[0].toInstant().toEpochMilli(),
                          e = end[0].toInstant().toEpochMilli();
                      if (!task && due.isChecked()) {
                        s = midnight(date[0].toLocalDate());
                        e = midnight(end[0].toLocalDate().plusDays(1));
                      }
                      final long start = s, finish = e;
                      if (task) {
                        String taskId =
                            existing == null ? UUID.randomUUID().toString() : existing.id();
                        store.task(
                            taskId,
                            name,
                            notes.getText().toString(),
                            due.isChecked() ? start : 0,
                            existing != null && existing.done());
                        store.taskList(
                            taskId, taskLists.get(lists.getSelectedItemPosition()).name());
                        dialog.dismiss();
                        render();
                        AgendaWidget.refresh(this);
                        return;
                      }
                      if (writable.isEmpty()) {
                        error("Connect iCloud and select a writable calendar in Settings first.");
                        return;
                      }
                      if (finish <= start) {
                        error("End must be after start.");
                        return;
                      }
                      String calendar = writable.get(calendars.getSelectedItemPosition()).id();
                      String raw =
                          existing == null
                              ? CalendarCodec.create(
                                  name,
                                  notes.getText().toString(),
                                  location.getText().toString(),
                                  start,
                                  finish,
                                  due.isChecked())
                              : CalendarCodec.edit(
                                  existing.raw(),
                                  name,
                                  notes.getText().toString(),
                                  location.getText().toString(),
                                  start,
                                  finish,
                                  due.isChecked());
                      dialog.getButton(-1).setEnabled(false);
                      executor.execute(
                          () -> {
                            try {
                              String[] a = new Vault(this).read();
                              new CalDav(a[0], a[1])
                                  .put(
                                      existing == null
                                          ? calendar + UUID.randomUUID() + ".ics"
                                          : existing.id(),
                                      raw,
                                      existing == null ? "*" : existing.etag());
                              runOnUiThread(
                                  () -> {
                                    dialog.dismiss();
                                    sync();
                                  });
                            } catch (Exception ex) {
                              runOnUiThread(
                                  () -> {
                                    dialog.getButton(-1).setEnabled(true);
                                    error(ex.getMessage());
                                  });
                            }
                          });
                    }));
    dialog.show();
  }

  private void pickDate(ZonedDateTime[] date, Runnable changed, boolean allDay) {
    ZonedDateTime d = date[0];
    new DatePickerDialog(
            this,
            (p, y, m, day) -> {
              date[0] = date[0].withDayOfMonth(1).withYear(y).withMonth(m + 1).withDayOfMonth(day);
              if (allDay) {
                changed.run();
                return;
              }
              new TimePickerDialog(
                      this,
                      (t, h, min) -> {
                        date[0] = date[0].withHour(h).withMinute(min).withSecond(0);
                        changed.run();
                      },
                      d.getHour(),
                      d.getMinute(),
                      false)
                  .show();
            },
            d.getYear(),
            d.getMonthValue() - 1,
            d.getDayOfMonth())
        .show();
  }

  private void settings() {
    title(settingsPage.isEmpty() ? "Settings" : settingsPage);
    if (settingsPage.isEmpty()) {
      String[] names = {"Calendars & Lists", "Agenda", "Widgets", "Appearance", "Alerts", "About"};
      String[] details = {
        "iCloud account, calendars, local reminder lists",
        "Earlier items and weekly planning",
        "Layouts, colors, text and reset",
        "Theme, accent color and text size",
        "Local reminders and event alerts",
        "Version, support and privacy"
      };
      for (int j = 0; j < names.length; j++) {
        String name = names[j];
        LinearLayout box = column();
        rounded(box, card);
        box.addView(text(name + "   ›", 18, ink));
        box.addView(text(details[j], 13, muted));
        box.setPadding(dp(10), dp(7), dp(10), dp(7));
        box.setOnClickListener(
            v -> {
              settingsPage = name;
              render();
            });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(8);
        body.addView(box, lp);
      }
      body.addView(text("© 2026 John Walter. All rights reserved.", 12, muted));
      return;
    }
    body.addView(
        button(
            "‹ Settings",
            () -> {
              settingsPage = "";
              render();
            }));
    if (!settingsPage.equals("Calendars & Lists")) {
      settingsDetail();
      return;
    }
    body.addView(text("ICLOUD ACCOUNT", 13, muted));
    boolean connected = false;
    try {
      connected = new Vault(this).read() != null;
    } catch (Exception ignored) {
    }
    body.addView(text(connected ? "iCloud connected" : "Connect your calendars", 19, ink));
    long last = prefs().getLong("lastSync", 0);
    body.addView(
        text(
            last == 0
                ? "Not synced yet"
                : "Last sync: "
                    + Instant.ofEpochMilli(last)
                        .atZone(ZoneId.systemDefault())
                        .format(DateTimeFormatter.ofPattern("MMM d, h:mm a")),
            13,
            muted));
    if (prefs().contains("syncError"))
      body.addView(text(prefs().getString("syncError", ""), 14, muted));
    body.addView(button(connected ? "Update app password" : "Connect iCloud", () -> login()));
    body.addView(button("Sync now", () -> sync()));
    if (connected)
      body.addView(
          button(
              "Disconnect iCloud",
              () ->
                  new AlertDialog.Builder(this)
                      .setMessage(
                          "Remove this account and its cached calendars from this Android device?"
                              + " Your iCloud events and local tasks are kept.")
                      .setNegativeButton("Cancel", null)
                      .setPositiveButton("Disconnect", (d, w) -> work(() -> Sync.disconnect(this)))
                      .show()));
    body.addView(text("CALENDARS", 13, muted));
    toggle("Birthdays & Contact Dates (iCloud Contacts)", "contacts", false, false);
    body.addView(
        button(
            "Contact date color",
            () -> colorPicker("contactColor", prefs().getInt("contactColor", 0xff8e8e93))));
    body.addView(
        text(
            "Sync after enabling to read birthdays, anniversaries, and other dated fields from"
                + " iCloud Contacts.",
            12,
            muted));
    for (var c : store.calendars()) {
      CheckBox toggle = new CheckBox(this);
      toggle.setText(c.name() + (c.writable() ? "" : " · read only"));
      toggle.setTextColor(ink);
      toggle.setChecked(c.selected());
      toggle.setOnCheckedChangeListener(
          (b, on) -> {
            store.select(c.id(), on);
            AgendaWidget.refresh(this);
          });
      body.addView(toggle);
    }
  }

  private void toggle(String label, String key, boolean def, boolean redraw) {
    Switch s = new Switch(this);
    s.setText(label);
    s.setTextColor(ink);
    s.setPadding(0, dp(10), 0, dp(10));
    s.setChecked(prefs().getBoolean(key, def));
    s.setOnCheckedChangeListener(
        (b, on) -> {
          prefs().edit().putBoolean(key, on).apply();
          if (key.equals("contacts")) {
            if (!on) store.contacts(List.of());
            else sync();
          }
          AgendaWidget.refresh(this);
          TaskAlerts.schedule(this);
          if (redraw) render();
        });
    body.addView(s);
  }

  private void login() {
    LinearLayout form = column();
    form.setPadding(dp(20), dp(8), dp(20), dp(8));
    form.addView(
        text(
            "Use your Apple Account email and an app-specific password from account.apple.com. Your"
                + " password is encrypted on this device and sent only to iCloud over HTTPS.",
            14,
            muted));
    EditText email = input(form, "Apple Account email", ""),
        password = input(form, "App-specific password", "");
    email.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
    password.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    password.setSaveEnabled(false);
    form.addView(
        button(
            "Create an app-specific password",
            () ->
                startActivity(
                    new Intent(
                        Intent.ACTION_VIEW, android.net.Uri.parse("https://account.apple.com/")))));
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("Connect iCloud")
            .setView(form)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Connect", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      String e = email.getText().toString().trim(),
                          p = password.getText().toString().trim();
                      if (!e.contains("@") || p.isBlank()) {
                        error("Enter your Apple Account email and app-specific password.");
                        return;
                      }
                      dialog.getButton(-1).setEnabled(false);
                      executor.execute(
                          () -> {
                            try {
                              Sync.connect(this, e, p);
                              runOnUiThread(
                                  () -> {
                                    password.setText("");
                                    dialog.dismiss();
                                    render();
                                  });
                            } catch (Exception ex) {
                              runOnUiThread(
                                  () -> {
                                    dialog.getButton(-1).setEnabled(true);
                                    error(ex.getMessage());
                                  });
                            }
                          });
                    }));
    dialog.show();
  }

  interface Operation {
    void run() throws Exception;
  }

  private void work(Operation op) {
    if (busy) return;
    busy = true;
    executor.execute(
        () -> {
          String problem = null;
          try {
            op.run();
          } catch (Exception e) {
            problem = e.getMessage();
            prefs().edit().putString("syncError", problem).apply();
          }
          String message = problem;
          runOnUiThread(
              () -> {
                busy = false;
                render();
                if (message != null) error(message);
              });
        });
  }

  private void sync() {
    work(() -> Sync.run(this));
  }

  private void error(String message) {
    new AlertDialog.Builder(this)
        .setTitle("LotsOfEvents")
        .setMessage(message == null ? "Could not complete this action. Try again." : message)
        .setPositiveButton("OK", null)
        .show();
  }

  private void openFromWidget(Intent intent) {
    if (intent.getBooleanExtra("reminders", false)) {
      tab = 2;
      render();
      return;
    }
    String id = intent.getStringExtra("item");
    if (id == null) return;
    long at = intent.getLongExtra("itemStart", System.currentTimeMillis());
    for (var item : read(Math.max(0, at - 86400000L), at + 86400000L, true, true))
      if (item.id().equals(id)) {
        details(item);
        return;
      }
  }

  private void quickAdd() {
    LinearLayout content = column();
    content.setPadding(dp(20), dp(12), dp(20), dp(12));
    TextView heading = text("Quick Add", 23, ink);
    content.addView(heading);
    EditText entry = input(content, "What would you like to add?", "");
    entry.setMinLines(2);
    LinearLayout choices = row();
    Button event =
        button(
            "Event",
            () -> {
              draftTitle = entry.getText().toString();
              quickDialog.dismiss();
              editor(null, false);
            });
    Button task =
        button(
            "Reminder",
            () -> {
              draftTitle = entry.getText().toString();
              quickDialog.dismiss();
              editor(null, true);
            });
    choices.addView(event, new LinearLayout.LayoutParams(0, -2, 1));
    choices.addView(task, new LinearLayout.LayoutParams(0, -2, 1));
    content.addView(choices);
    content.addView(
        text(
            "Choose an event or a local reminder, then confirm the date and details. Reminders may"
                + " have no due date.",
            14,
            muted));
    content.addView(
        button(
            "Speak",
            () -> {
              try {
                Intent i =
                    new Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                        .putExtra(
                            android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                            android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
                speechField = entry;
                startActivityForResult(i, 41);
              } catch (Exception e) {
                error("Speech recognition is not available on this device.");
              }
            }));
    content.setBackgroundColor(card);
    quickDialog = new Dialog(this);
    quickDialog.setContentView(content);
    quickDialog.show();
    quickDialog.getWindow().setGravity(Gravity.BOTTOM);
    quickDialog.getWindow().setLayout(-1, getResources().getDisplayMetrics().heightPixels / 2);
  }

  private Dialog quickDialog;
  private EditText speechField;
  private String draftTitle = "";

  @Override
  protected void onActivityResult(int request, int result, Intent data) {
    super.onActivityResult(request, result, data);
    if (request == 41 && result == RESULT_OK && speechField != null && data != null) {
      var words = data.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS);
      if (words != null && !words.isEmpty()) speechField.setText(words.get(0));
    }
  }

  private void alternateCalendar() {
    if (calendarMode == 4) {
      LinearLayout h = row();
      h.addView(
          button(
              "‹",
              () -> {
                month = month.minusYears(1);
                render();
              }));
      h.addView(text("" + month.getYear(), 23, ink), new LinearLayout.LayoutParams(0, -2, 1));
      h.addView(
          button(
              "›",
              () -> {
                month = month.plusYears(1);
                render();
              }));
      body.addView(h);
      for (int r = 0; r < 4; r++) {
        LinearLayout line = row();
        for (int col = 0; col < 3; col++) {
          YearMonth m = YearMonth.of(month.getYear(), r * 3 + col + 1);
          Button b =
              button(
                  m.format(DateTimeFormatter.ofPattern("MMMM")),
                  () -> {
                    month = m;
                    calendarMode = 0;
                    render();
                  });
          line.addView(b, new LinearLayout.LayoutParams(0, dp(86), 1));
        }
        body.addView(line);
      }
      return;
    }
    int count = calendarMode == 1 ? 1 : calendarMode == 2 ? 3 : 7;
    LocalDate first =
        calendarMode == 3 ? selected.minusDays(selected.getDayOfWeek().getValue() % 7) : selected;
    LinearLayout h = row();
    h.addView(
        button(
            "‹",
            () -> {
              selected = selected.minusDays(count);
              render();
            }));
    h.addView(
        text(first.format(DateTimeFormatter.ofPattern("MMM d")), 21, ink),
        new LinearLayout.LayoutParams(0, -2, 1));
    h.addView(
        button(
            "›",
            () -> {
              selected = selected.plusDays(count);
              render();
            }));
    body.addView(h);
    timeline(first, count);
  }

  private long draftStart;

  private void timeline(LocalDate first, int count) {
    LinearLayout labels = row();
    labels.addView(text("", 12, muted), new LinearLayout.LayoutParams(dp(42), dp(40)));
    for (int d = 0; d < count; d++) {
      LocalDate day = first.plusDays(d);
      TextView label =
          text(day.format(DateTimeFormatter.ofPattern("EEE d")), count > 3 ? 11 : 15, ink);
      label.setGravity(Gravity.CENTER);
      labels.addView(label, new LinearLayout.LayoutParams(0, dp(40), 1));
    }
    body.addView(labels);
    var events = read(midnight(first), midnight(first.plusDays(count)), false, false);
    for (var item : events) if (item.allDay()) item(item);
    LinearLayout lanes = row();
    FrameLayout hours = new FrameLayout(this);
    lanes.addView(hours, new LinearLayout.LayoutParams(dp(42), dp(24 * 56)));
    for (int h = 0; h < 24; h++) {
      TextView label = text(String.format(Locale.getDefault(), "%02d", h), 11, muted);
      FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(-1, dp(24));
      lp.topMargin = dp(h * 56);
      hours.addView(label, lp);
    }
    for (int d = 0; d < count; d++) {
      LocalDate day = first.plusDays(d);
      FrameLayout lane = new FrameLayout(this);
      lanes.addView(lane, new LinearLayout.LayoutParams(0, dp(24 * 56), 1));
      for (int h = 0; h < 24; h++) {
        View line = new View(this);
        line.setBackgroundColor(card);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(-1, dp(1));
        lp.topMargin = dp(h * 56);
        lane.addView(line, lp);
      }
      var dayEvents =
          events.stream()
              .filter(i -> !i.allDay() && WidgetData.overlaps(i, day))
              .collect(java.util.stream.Collectors.toList());
      lane.post(
          () -> {
            int width = lane.getWidth();
            for (var item : dayEvents) {
              var start =
                  Instant.ofEpochMilli(Math.max(midnight(day), item.start()))
                      .atZone(ZoneId.systemDefault());
              int minute = start.getHour() * 60 + start.getMinute();
              int duration =
                  (int)
                      Math.max(
                          20,
                          Math.min(
                              1440 - minute,
                              (item.end() - Math.max(midnight(day), item.start())) / 60000));
              int overlaps =
                  (int)
                      dayEvents.stream()
                          .filter(
                              other ->
                                  other.start() < Math.max(item.start() + 1, item.end())
                                      && Math.max(other.start() + 1, other.end()) > item.start())
                          .count();
              int index = 0;
              for (var other : dayEvents) {
                if (other == item) break;
                if (other.start() < Math.max(item.start() + 1, item.end())
                    && Math.max(other.start() + 1, other.end()) > item.start()) index++;
              }
              TextView label =
                  text(
                      item.title() + "\n" + WidgetData.clock(item.start()),
                      count > 3 ? 10 : 12,
                      ink);
              label.setMaxLines(Math.max(1, duration / 20));
              label.setEllipsize(android.text.TextUtils.TruncateAt.END);
              rounded(label, (item.color() & 0xffffff) | 0x55000000);
              FrameLayout.LayoutParams lp =
                  new FrameLayout.LayoutParams(
                      Math.max(dp(12), width / Math.max(1, overlaps) - dp(2)),
                      dp(duration * 56 / 60));
              lp.topMargin = dp(minute * 56 / 60);
              lp.leftMargin = index * width / Math.max(1, overlaps);
              lane.addView(label, lp);
              label.setOnClickListener(v -> details(item));
            }
          });
      final float[] touch = new float[2];
      lane.setOnTouchListener(
          (v, e) -> {
            if (e.getActionMasked() == MotionEvent.ACTION_DOWN) {
              touch[0] = e.getX();
              touch[1] = e.getY();
              return true;
            }
            if (e.getActionMasked() == MotionEvent.ACTION_UP
                && Math.abs(e.getX() - touch[0]) + Math.abs(e.getY() - touch[1]) < dp(12)) {
              int minutes = Math.max(0, Math.min(1425, Math.round(e.getY() / dp(56) * 4) * 15));
              selected = day;
              draftStart =
                  day.atTime(minutes / 60, minutes % 60)
                      .atZone(ZoneId.systemDefault())
                      .toInstant()
                      .toEpochMilli();
              editor(null, false);
              return true;
            }
            return true;
          });
    }
    body.addView(lanes);
  }

  private void weeklyPlanner() {
    LinearLayout form = column();
    form.setPadding(dp(18), dp(12), dp(18), dp(12));
    form.addView(text("Weekly Planner", 24, ink));
    form.addView(text("Schedule an undated or overdue local task", 14, muted));
    long today = midnight(LocalDate.now());
    for (var i : store.items(0, Long.MAX_VALUE, true, false))
      if (i.task() && (i.start() == 0 || i.start() < today))
        form.addView(
            button(
                i.title(),
                () -> {
                  final ZonedDateTime[] day = {ZonedDateTime.now().withHour(9).withMinute(0)};
                  pickDate(
                      day,
                      () -> {
                        store.task(
                            i.id(), i.title(), i.notes(), day[0].toInstant().toEpochMilli(), false);
                        AgendaWidget.refresh(this);
                        render();
                      },
                      false);
                }));
    for (int n = 0; n < 7; n++) {
      LocalDate d = LocalDate.now().plusDays(n);
      form.addView(text(WidgetData.dateLabel(d), 15, muted));
      for (var i : store.items(midnight(d), midnight(d.plusDays(1)), false, false))
        form.addView(button(i.title(), () -> details(i)));
    }
    ScrollView scroll = new ScrollView(this);
    scroll.addView(form);
    new AlertDialog.Builder(this).setView(scroll).setNegativeButton("Close", null).show();
  }

  private void settingsDetail() {
    switch (settingsPage) {
      case "Agenda":
        toggle("Show earlier events today", "past", true, false);
        body.addView(button("Open Weekly Planner", () -> weeklyPlanner()));
        break;
      case "Appearance":
        body.addView(text("Theme", 16, muted));
        choose(
            Palette.NAMES,
            prefs().getInt("theme", 2),
            n -> {
              prefs().edit().putInt("theme", n).apply();
              render();
              AgendaWidget.refresh(this);
            });
        body.addView(button("Accent color", () -> colorPicker("accent", accent)));
        if (prefs().getInt("theme", 2) == 6) {
          String[] keys = {"paper", "card", "ink", "muted", "accent"};
          int[] colors = Palette.app(this);
          for (int j = 0; j < keys.length; j++) {
            String key = keys[j];
            int color = colors[j];
            body.addView(button("Custom " + key, () -> colorPicker("custom_" + key, color)));
          }
        }
        break;
      case "Widgets":
        body.addView(text("Widget theme", 16, muted));
        choose(
            Palette.WIDGETS,
            prefs().getInt("widgetTheme", 0),
            n -> {
              prefs().edit().putInt("widgetTheme", n).apply();
              AgendaWidget.refresh(this);
            });
        body.addView(button("Custom background", () -> colorPicker("widgetBg", card)));
        body.addView(button("Custom text", () -> colorPicker("widgetInk", ink)));
        body.addView(button("Custom secondary text", () -> colorPicker("widgetMuted", muted)));
        body.addView(text("Days Ahead · including today", 16, muted));
        String[] days = new String[13];
        for (int n = 0; n < 13; n++) days[n] = "" + (n + 2);
        choose(
            days,
            prefs().getInt("days", 5) - 2,
            n -> {
              prefs().edit().putInt("days", n + 2).apply();
              AgendaWidget.refresh(this);
            });
        body.addView(text("Widget gallery", 18, ink));
        for (int k = 0; k < WidgetData.NAMES.length; k++) {
          int kind = k;
          body.addView(
              button(
                  WidgetData.NAMES[k] + "  +",
                  () -> {
                    var manager = android.appwidget.AppWidgetManager.getInstance(this);
                    if (manager.isRequestPinAppWidgetSupported())
                      manager.requestPinAppWidget(
                          new ComponentName(this, AgendaWidget.TYPES[kind]), null, null);
                    else error("Long-press the Home Screen and choose Widgets → LotsOfEvents.");
                  }));
        }
        body.addView(
            text(
                "Use ⋯ on each widget to change its calendars, text, spacing, times, task"
                    + " visibility, and reset delay. Lists scroll; Events + Tasks uses Days Ahead"
                    + " only when Include Upcoming Days is enabled.",
                14,
                muted));
        break;
      case "Alerts":
        body.addView(text("Local reminder notifications", 18, ink));
        toggle("Notify for dated local reminders", "notify", true, false);
        body.addView(
            button(
                "Allow notifications",
                () -> {
                  if (android.os.Build.VERSION.SDK_INT >= 33)
                    requestPermissions(
                        new String[] {android.Manifest.permission.POST_NOTIFICATIONS}, 42);
                }));
        body.addView(
            text(
                "Android may delay alerts to save battery. iCloud event alarms remain in Apple"
                    + " Calendar.",
                14,
                muted));
        break;
      case "About":
        body.addView(text("LotsOfEvents for Android · 0.1", 20, ink));
        body.addView(
            text(
                "Calendars sync directly with iCloud. Modern iCloud Reminders cannot sync with an"
                    + " app-specific password. Android reminders are local to this device. No"
                    + " weather features or developer-operated servers.",
                15,
                muted));
        body.addView(
            button(
                "Support",
                () ->
                    startActivity(
                        new Intent(
                            Intent.ACTION_SENDTO,
                            android.net.Uri.parse("mailto:LotsOfEvents@jwalter.net")))));
        body.addView(text("© 2026 John Walter. All rights reserved.", 13, muted));
        break;
    }
  }

  private void choose(String[] options, int selected, java.util.function.IntConsumer changed) {
    Spinner s = new Spinner(this);
    s.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, options));
    s.setSelection(selected);
    s.setOnItemSelectedListener(
        new AdapterView.OnItemSelectedListener() {
          boolean initial = true;

          public void onNothingSelected(AdapterView<?> p) {}

          public void onItemSelected(AdapterView<?> p, View v, int n, long id) {
            if (initial) {
              initial = false;
              return;
            }
            changed.accept(n);
          }
        });
    body.addView(s);
  }

  private void colorPicker(String key, int current) {
    EditText hex = new EditText(this);
    hex.setText(String.format(Locale.ROOT, "#%06X", current & 0xffffff));
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("Choose color · #RRGGBB")
            .setView(hex)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Save", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      try {
                        int color = Color.parseColor(hex.getText().toString());
                        prefs().edit().putInt(key, color).apply();
                        dialog.dismiss();
                        render();
                        AgendaWidget.refresh(this);
                      } catch (Exception e) {
                        hex.setError("Use # followed by six hexadecimal digits");
                      }
                    }));
    dialog.show();
  }
}
