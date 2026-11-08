package net.jwalter.lotsofevents;

import static org.junit.Assert.*;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.util.*;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public class RuntimeTest {
  @Test
  public void parsesDavXmlOnAndroid() throws Exception {
    assertEquals(
        "Calendar",
        CalDav.xml("<d:prop xmlns:d='DAV:'><d:displayname>Calendar</d:displayname></d:prop>")
            .getDocumentElement()
            .getTextContent());
  }

  @Test
  public void encryptsCredentialsAndRemovesThem() throws Exception {
    var c = InstrumentationRegistry.getInstrumentation().getTargetContext();
    Vault v = new Vault(c);
    v.save("test@example.invalid", "test-app-password");
    assertEquals("test-app-password", v.read()[1]);
    assertFalse(
        c.getSharedPreferences("vault", 0).getString("data", "").contains("test-app-password"));
    v.clear();
    assertNull(v.read());
  }

  @Test
  public void localUndatedTaskSurvivesCalendarDisconnect() {
    var c = InstrumentationRegistry.getInstrumentation().getTargetContext();
    String id = UUID.randomUUID().toString();
    try (Store s = new Store(c)) {
      s.task(id, "Runtime test task", "", 0, false);
      s.disconnect();
      assertTrue(s.items(0, Long.MAX_VALUE, true, false).stream().anyMatch(i -> i.id().equals(id)));
      s.task(id, "Runtime test task", "", 0, true);
      assertFalse(
          s.items(0, Long.MAX_VALUE, true, false).stream().anyMatch(i -> i.id().equals(id)));
      s.removeTask(id);
    }
  }
  @Test
  public void mainScreensLaunchWithoutInsetsCrash() {
    var context=InstrumentationRegistry.getInstrumentation().getTargetContext();
    for(String screen:new String[]{"agenda","calendar","reminders","settings"}) {
      var intent=new android.content.Intent(context,MainActivity.class).putExtra("screen",screen);
      try(var scenario=androidx.test.core.app.ActivityScenario.<MainActivity>launch(intent)) {
        scenario.onActivity(activity -> assertNotNull(activity.getWindow().getDecorView()));
      }
    }
  }
}
