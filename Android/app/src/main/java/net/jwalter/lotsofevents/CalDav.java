package net.jwalter.lotsofevents;

import java.io.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.TimeUnit;
import javax.xml.parsers.DocumentBuilderFactory;
import okhttp3.*;
import org.w3c.dom.*;

public final class CalDav {
  public record CalendarInfo(String url, String name, String color, boolean writable) {}

  public record Resource(String url, String etag, String text) {}

  private final OkHttpClient client;
  private final String auth;

  public CalDav(String email, String password) {
    this(
        email,
        password,
        new OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .callTimeout(60, TimeUnit.SECONDS)
            .build());
  }

  CalDav(String email, String password, OkHttpClient client) {
    this.client = client;
    auth = Credentials.basic(email, password);
  }

  static boolean trusted(String url) {
    try {
      HttpUrl u = HttpUrl.get(url);
      return u.isHttps()
          && u.port() == 443
          && (u.host().equals("icloud.com") || u.host().endsWith(".icloud.com"))
          && u.username().isEmpty()
          && u.password().isEmpty();
    } catch (Exception e) {
      return false;
    }
  }

  Response send(String url, String method, String body, String etag) throws IOException {
    for (int redirects = 0; redirects < 5; redirects++) {
      if (!trusted(url)) throw new IOException("iCloud returned an untrusted server address.");
      Request.Builder b =
          new Request.Builder()
              .url(url)
              .header("Authorization", auth)
              .header("User-Agent", "LotsOfEvents-Android/0.1")
              .header(
                  "Depth", method.equals("PROPFIND") && !body.contains("resourcetype") ? "0" : "1");
      if (etag != null) b.header(etag.equals("*") ? "If-None-Match" : "If-Match", etag);
      b.method(
          method,
          body == null
              ? null
              : RequestBody.create(
                  body,
                  MediaType.get(
                      method.equals("PUT")
                          ? "text/calendar; charset=utf-8"
                          : "application/xml; charset=utf-8")));
      Response r = client.newCall(b.build()).execute();
      if (r.code() == 301 || r.code() == 302 || r.code() == 307 || r.code() == 308) {
        String next = r.header("Location");
        HttpUrl resolved = next == null ? null : r.request().url().resolve(next);
        r.close();
        if (resolved == null) throw new IOException("Invalid iCloud redirect.");
        url = resolved.toString();
        continue;
      }
      if (r.code() == 401 || r.code() == 403) {
        r.close();
        throw new IOException(
            "iCloud denied access. Check your Apple Account email and app-specific password, and"
                + " whether this calendar is writable.");
      }
      if (r.code() == 412) {
        r.close();
        throw new IOException(
            "This event changed on another device. Sync again before editing; your changes were not"
                + " uploaded.");
      }
      if (!r.isSuccessful()) {
        int code = r.code();
        r.close();
        throw new IOException(
            "iCloud request failed (" + code + "). Your saved calendar data has been kept.");
      }
      return r;
    }
    throw new IOException("Too many iCloud redirects.");
  }

  static Document xml(String text) throws Exception {
    if (java.util.regex.Pattern.compile(
            "<!\\s*(DOCTYPE|ENTITY)", java.util.regex.Pattern.CASE_INSENSITIVE)
        .matcher(text)
        .find()) throw new org.xml.sax.SAXException("Document declarations are not allowed.");
    DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
    f.setNamespaceAware(true);
    f.setExpandEntityReferences(false);
    try {
      f.setFeature("http://xml.org/sax/features/external-general-entities", false);
      f.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
    } catch (javax.xml.parsers.ParserConfigurationException ignored) {
    }
    var builder = f.newDocumentBuilder();
    builder.setEntityResolver(
        (publicId, systemId) -> {
          throw new org.xml.sax.SAXException("External entities are not allowed.");
        });
    return builder.parse(
        new ByteArrayInputStream(text.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
  }

  static String value(Element e, String ns, String name) {
    NodeList n = e.getElementsByTagNameNS(ns, name);
    return n.getLength() == 0 ? "" : n.item(0).getTextContent();
  }

  private Document prop(String url, String fields) throws Exception {
    try (Response r =
        send(
            url,
            "PROPFIND",
            "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\""
                + " xmlns:c=\"urn:ietf:params:xml:ns:caldav\""
                + " xmlns:a=\"http://apple.com/ns/ical/\"><d:prop>"
                + fields
                + "</d:prop></d:propfind>",
            null)) {
      return xml(r.body().string());
    }
  }

  private String propertyHref(Document d, String ns, String property) throws Exception {
    NodeList n = d.getElementsByTagNameNS(ns, property);
    for (int i = 0; i < n.getLength(); i++) {
      String h = value((Element) n.item(i), "DAV:", "href");
      if (!h.isBlank()) return h;
    }
    throw new IOException("iCloud did not provide calendar discovery information.");
  }

  public List<CalendarInfo> discover() throws Exception {
    String root = "https://caldav.icloud.com/";
    String principal =
        HttpUrl.get(root)
            .resolve(
                propertyHref(
                    prop(root, "<d:current-user-principal/>"), "DAV:", "current-user-principal"))
            .toString();
    String home =
        HttpUrl.get(principal)
            .resolve(
                propertyHref(
                    prop(principal, "<c:calendar-home-set/>"),
                    "urn:ietf:params:xml:ns:caldav",
                    "calendar-home-set"))
            .toString();
    Document d =
        prop(
            home,
            "<d:displayname/><d:resourcetype/><a:calendar-color/><d:current-user-privilege-set/><c:supported-calendar-component-set/>");
    List<CalendarInfo> out = new ArrayList<>();
    NodeList responses = d.getElementsByTagNameNS("DAV:", "response");
    for (int i = 0; i < responses.getLength(); i++) {
      Element e = (Element) responses.item(i);
      if (e.getElementsByTagNameNS("urn:ietf:params:xml:ns:caldav", "calendar").getLength() == 0)
        continue;
      NodeList comps = e.getElementsByTagNameNS("urn:ietf:params:xml:ns:caldav", "comp");
      boolean events = comps.getLength() == 0;
      for (int k = 0; k < comps.getLength(); k++)
        if (((Element) comps.item(k)).getAttribute("name").equals("VEVENT")) events = true;
      if (!events) continue;
      String href = HttpUrl.get(home).resolve(value(e, "DAV:", "href")).toString();
      if (!trusted(href)) throw new IOException("Unexpected calendar server.");
      boolean writable =
          e.getElementsByTagNameNS("DAV:", "write").getLength() > 0
              || e.getElementsByTagNameNS("DAV:", "write-content").getLength() > 0
              || e.getElementsByTagNameNS("DAV:", "all").getLength() > 0;
      out.add(
          new CalendarInfo(
              href,
              value(e, "DAV:", "displayname"),
              value(e, "http://apple.com/ns/ical/", "calendar-color"),
              writable));
    }
    return out;
  }

  public List<Resource> events(String calendar, Instant from, Instant to) throws Exception {
    var format = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC);
    String query =
        "<c:calendar-query xmlns:d=\"DAV:\""
            + " xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter"
            + " name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\"><c:time-range start=\""
            + format.format(from)
            + "\" end=\""
            + format.format(to)
            + "\"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>";
    try (Response r = send(calendar, "REPORT", query, null)) {
      Document d = xml(r.body().string());
      NodeList nodes = d.getElementsByTagNameNS("DAV:", "response");
      List<Resource> out = new ArrayList<>();
      for (int i = 0; i < nodes.getLength(); i++) {
        Element e = (Element) nodes.item(i);
        String text = value(e, "urn:ietf:params:xml:ns:caldav", "calendar-data");
        if (text.isEmpty())
          throw new IOException(
              "iCloud returned an incomplete event response. Existing data was kept.");
        if (!text.isEmpty())
          out.add(
              new Resource(
                  HttpUrl.get(calendar).resolve(value(e, "DAV:", "href")).toString(),
                  value(e, "DAV:", "getetag"),
                  text));
      }
      return out;
    }
  }

  public void put(String url, String text, String etag) throws Exception {
    if (etag == null || etag.isBlank())
      throw new IOException("Missing event version. Sync before saving.");
    try (Response ignored = send(url, "PUT", text, etag)) {}
  }

  public void delete(String url, String etag) throws Exception {
    if (etag == null || etag.isBlank())
      throw new IOException("Missing event version. Sync before deleting.");
    try (Response ignored = send(url, "DELETE", null, etag)) {}
  }

  public List<String> contacts() throws Exception {
    String root = "https://contacts.icloud.com/";
    String principal =
        HttpUrl.get(root)
            .resolve(
                propertyHref(
                    prop(root, "<d:current-user-principal/>"), "DAV:", "current-user-principal"))
            .toString();
    String home;
    String query =
        "<d:propfind xmlns:d=\"DAV:\""
            + " xmlns:a=\"urn:ietf:params:xml:ns:carddav\"><d:prop><a:addressbook-home-set/></d:prop></d:propfind>";
    try (Response r = send(principal, "PROPFIND", query, null)) {
      home =
          HttpUrl.get(principal)
              .resolve(
                  propertyHref(
                      xml(r.body().string()),
                      "urn:ietf:params:xml:ns:carddav",
                      "addressbook-home-set"))
              .toString();
    }
    Document d = prop(home, "<d:resourcetype/>");
    List<String> cards = new ArrayList<>();
    NodeList responses = d.getElementsByTagNameNS("DAV:", "response");
    for (int n = 0; n < responses.getLength(); n++) {
      Element e = (Element) responses.item(n);
      if (e.getElementsByTagNameNS("urn:ietf:params:xml:ns:carddav", "addressbook").getLength()
          == 0) continue;
      String url = HttpUrl.get(home).resolve(value(e, "DAV:", "href")).toString();
      String report =
          "<a:addressbook-query xmlns:d=\"DAV:\""
              + " xmlns:a=\"urn:ietf:params:xml:ns:carddav\"><d:prop><a:address-data/></d:prop></a:addressbook-query>";
      try (Response r = send(url, "REPORT", report, null)) {
        NodeList data =
            xml(r.body().string())
                .getElementsByTagNameNS("urn:ietf:params:xml:ns:carddav", "address-data");
        for (int j = 0; j < data.getLength(); j++) cards.add(data.item(j).getTextContent());
      }
    }
    return cards;
  }
}
