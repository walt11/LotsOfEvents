package net.jwalter.lotsofevents;

import android.content.*;
import android.graphics.Color;

final class Palette {
  static final String[] NAMES = {
    "Light", "Dark", "Graphite", "Midnight", "Forest", "Studio", "Custom"
  };
  static final int[][] COLORS = {
    {0xfff2f2f7, 0xffffffff, 0xff000000, 0xff6c6c70, 0xff0062cc},
    {0xff000000, 0xff1c1c1e, 0xffffffff, 0xff98989f, 0xff409cff},
    {0xff0d0e0f, 0xff1a1b1d, 0xffecedee, 0xffa2a5aa, 0xff8db4de},
    {0xff0a0f1c, 0xff141c2e, 0xffe8edf7, 0xff9aa6bd, 0xff64d2ff},
    {0xff0e1411, 0xff18211c, 0xffe6eee8, 0xff9db0a4, 0xff30d158},
    {0xfff2f2f0, 0xfff7f5ed, 0xff292b2e, 0xff5c5e63, 0xffa9401f}
  };

  static int[] app(Context c) {
    var p = c.getSharedPreferences("settings", 0);
    int n = Math.max(0, Math.min(6, p.getInt("theme", 2)));
    int[] colors = COLORS[Math.min(n, 5)].clone();
    if (n == 6) {
      String[] keys = {"paper", "card", "ink", "muted", "accent"};
      for (int i = 0; i < 5; i++) colors[i] = p.getInt("custom_" + keys[i], COLORS[2][i]);
    }
    colors[4] = p.getInt("accent", colors[4]);
    return colors;
  }

  static final String[] WIDGETS = {
    "Match App Theme",
    "Charcoal",
    "Soft Gallery",
    "Graphite",
    "Slate",
    "Sage",
    "Sand",
    "Clay",
    "Lavender",
    "Black",
    "Custom"
  };

  static int[] widget(Context c, int theme) {
    int[] app = app(c);
    boolean dark = Color.luminance(app[0]) < 0.3;
    int[][] darks = {
      {0xff202022, 0xffffffff},
      {0xff2a3038, 0xffecedee},
      {0xff101112, 0xffecedee},
      {0xff121920, 0xffecedee},
      {0xff161d17, 0xffecedee},
      {0xff1d1914, 0xffecedee},
      {0xff201715, 0xffecedee},
      {0xff1a1621, 0xffecedee},
      {0xff000000, 0xffe0ddd7}
    };
    int[][] lights = {
      {0xff202022, 0xffffffff},
      {0xfffffdf8, 0xff342d27},
      {0xffd2d0cc, 0xff292b2d},
      {0xffc6ced3, 0xff293b49},
      {0xffc9cfc3, 0xff303f31},
      {0xffd5cbba, 0xff493e2e},
      {0xffd4c3b9, 0xff50372e},
      {0xffccc5d3, 0xff41354e},
      {0xff000000, 0xffe0ddd7}
    };
    if (theme == 0) return new int[] {app[1], app[2], app[3], app[4]};
    if (theme == 10) {
      var p = c.getSharedPreferences("settings", 0);
      return new int[] {
        p.getInt("widgetBg", app[1]),
        p.getInt("widgetInk", app[2]),
        p.getInt("widgetMuted", app[3]),
        app[4]
      };
    }
    int[] v = (dark ? darks : lights)[Math.max(0, Math.min(8, theme - 1))];
    return new int[] {v[0], v[1], (v[1] & 0xffffff) | 0xb0000000, app[4]};
  }
}
