package net.jwalter.lotsofevents;

import android.app.job.*;
import android.content.*;

public class SyncJob extends JobService {
  static void schedule(Context c) {
    c.getSystemService(JobScheduler.class)
        .schedule(
            new JobInfo.Builder(29, new ComponentName(c, SyncJob.class))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(30 * 60 * 1000)
                .setPersisted(true)
                .build());
  }

  public boolean onStartJob(JobParameters p) {
    new Thread(
            () -> {
              try {
                Sync.run(this);
              } catch (Exception e) {
                getSharedPreferences("settings", 0)
                    .edit()
                    .putString("syncError", e.getMessage())
                    .apply();
              }
              jobFinished(p, false);
            })
        .start();
    return true;
  }

  public boolean onStopJob(JobParameters p) {
    return true;
  }
}
