package net.jwalter.lotsofevents;

import android.app.*;
import android.content.*;
import android.os.Build;

public class TaskAlerts extends BroadcastReceiver {
  static void schedule(Context c) {
    AlarmManager a = c.getSystemService(AlarmManager.class);
    PendingIntent p =
        PendingIntent.getBroadcast(
            c,
            0,
            new Intent(c, TaskAlerts.class),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    a.cancel(p);
    if (!c.getSharedPreferences("settings", 0).getBoolean("notify", true)) return;
    long earliest = Long.MAX_VALUE, now = System.currentTimeMillis();
    try (Store s = new Store(c)) {
      for (var i : s.items(0, Long.MAX_VALUE, true, false))
        if (i.start() > now) earliest = Math.min(earliest, i.start());
    }
    if (earliest != Long.MAX_VALUE) a.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, earliest, p);
  }

  public void onReceive(Context c, Intent intent) {
    var settings = c.getSharedPreferences("settings", 0);
    if (!settings.getBoolean("notify", true)) return;
    NotificationManager m = c.getSystemService(NotificationManager.class);
    m.createNotificationChannel(
        new NotificationChannel(
            "tasks", "Reminder alerts", NotificationManager.IMPORTANCE_DEFAULT));
    long now = System.currentTimeMillis(), last = settings.getLong("lastAlert", now - 3600000);
    try (Store s = new Store(c)) {
      for (var i : s.items(Math.max(1, last), now + 1, false, false))
        if (i.task() && !i.done()) {
          Intent open =
              new Intent(c, MainActivity.class)
                  .putExtra("reminders", true)
                  .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
          var p =
              PendingIntent.getActivity(
                  c,
                  i.id().hashCode(),
                  open,
                  PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
          if (Build.VERSION.SDK_INT < 33
              || c.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                  == android.content.pm.PackageManager.PERMISSION_GRANTED)
            m.notify(
                i.id().hashCode(),
                new Notification.Builder(c, "tasks")
                    .setSmallIcon(android.R.drawable.ic_menu_my_calendar)
                    .setContentTitle(i.title())
                    .setContentText("Local reminder")
                    .setContentIntent(p)
                    .setAutoCancel(true)
                    .build());
        }
    }
    settings.edit().putLong("lastAlert", now + 1).apply();
    schedule(c);
  }
}
