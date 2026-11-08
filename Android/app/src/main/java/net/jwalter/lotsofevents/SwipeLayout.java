package net.jwalter.lotsofevents;

import android.content.Context;
import android.view.MotionEvent;
import android.widget.LinearLayout;

final class SwipeLayout extends LinearLayout {
  private float x, y;
  private final java.util.function.IntConsumer action;

  SwipeLayout(Context c, java.util.function.IntConsumer action) {
    super(c);
    setOrientation(VERTICAL);
    this.action = action;
  }

  public boolean onInterceptTouchEvent(MotionEvent e) {
    if (e.getActionMasked() == MotionEvent.ACTION_DOWN) {
      x = e.getX();
      y = e.getY();
    }
    return e.getActionMasked() == MotionEvent.ACTION_MOVE
        && Math.abs(e.getX() - x) > 60
        && Math.abs(e.getX() - x) > Math.abs(e.getY() - y) * 1.5;
  }

  public boolean onTouchEvent(MotionEvent e) {
    if (e.getActionMasked() == MotionEvent.ACTION_UP && Math.abs(e.getX() - x) > 60) {
      action.accept(e.getX() < x ? 1 : -1);
      return true;
    }
    return true;
  }
}
