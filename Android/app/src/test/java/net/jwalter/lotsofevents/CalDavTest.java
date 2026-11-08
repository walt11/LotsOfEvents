package net.jwalter.lotsofevents;

import static org.junit.Assert.*;

import java.io.*;
import java.time.*;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.*;
import org.junit.Test;

public class CalDavTest {
  private Response response(Request r, int code, String body) {
    return new Response.Builder()
        .request(r)
        .protocol(Protocol.HTTP_1_1)
        .code(code)
        .message("Test")
        .body(ResponseBody.create(body, MediaType.get("application/xml")))
        .build();
  }

  @Test
  public void discoversPrincipalHomeAndWritableCalendars() throws Exception {
    AtomicInteger calls = new AtomicInteger();
    OkHttpClient client =
        new OkHttpClient.Builder()
            .addInterceptor(
                chain -> {
                  Request r = chain.request();
                  assertNotNull(r.header("Authorization"));
                  int n = calls.getAndIncrement();
                  String content =
                      n == 0
                          ? "<d:current-user-principal><d:href>/123/principal/</d:href></d:current-user-principal>"
                          : n == 1
                              ? "<c:calendar-home-set><d:href>https://p01-caldav.icloud.com/123/calendars/</d:href></c:calendar-home-set>"
                              : "<d:response><d:href>/123/calendars/home/</d:href><d:propstat><d:prop><d:resourcetype><c:calendar/></d:resourcetype><d:displayname>Home</d:displayname><d:current-user-privilege-set><d:privilege><d:write/></d:privilege></d:current-user-privilege-set></d:prop></d:propstat></d:response>";
                  assertEquals(n == 2 ? "1" : "0", r.header("Depth"));
                  return response(
                      r,
                      207,
                      "<d:multistatus xmlns:d='DAV:' xmlns:c='urn:ietf:params:xml:ns:caldav'>"
                          + content
                          + "</d:multistatus>");
                })
            .build();
    var calendars = new CalDav("test@example.invalid", "fake", client).discover();
    assertEquals(1, calendars.size());
    assertEquals("Home", calendars.get(0).name());
    assertTrue(calendars.get(0).writable());
    assertEquals(3, calls.get());
  }

  @Test
  public void refusesCredentialRedirectBeforeSecondRequest() throws Exception {
    AtomicInteger calls = new AtomicInteger();
    var client =
        new OkHttpClient.Builder()
            .addInterceptor(
                chain -> {
                  calls.incrementAndGet();
                  return response(chain.request(), 302, "")
                      .newBuilder()
                      .header("Location", "https://attacker.invalid/")
                      .build();
                })
            .build();
    try {
      new CalDav("test@example.invalid", "fake", client).discover();
      fail();
    } catch (IOException expected) {
      assertTrue(expected.getMessage().contains("untrusted"));
    }
    assertEquals(1, calls.get());
  }

  @Test
  public void editsUseEtagAndConflictsFail() throws Exception {
    var client =
        new OkHttpClient.Builder()
            .addInterceptor(
                chain -> {
                  assertEquals("\"v1\"", chain.request().header("If-Match"));
                  return response(chain.request(), 412, "");
                })
            .build();
    try {
      new CalDav("test@example.invalid", "fake", client)
          .put("https://caldav.icloud.com/event.ics", "BEGIN:VCALENDAR", "\"v1\"");
      fail();
    } catch (IOException expected) {
      assertTrue(expected.getMessage().contains("changed on another device"));
    }
  }

  @Test
  public void createsCannotOverwriteExistingResource() throws Exception {
    var client =
        new OkHttpClient.Builder()
            .addInterceptor(
                chain -> {
                  assertEquals("*", chain.request().header("If-None-Match"));
                  assertNull(chain.request().header("If-Match"));
                  return response(chain.request(), 201, "");
                })
            .build();
    new CalDav("test@example.invalid", "fake", client)
        .put("https://caldav.icloud.com/new.ics", "BEGIN:VCALENDAR", "*");
  }
}
