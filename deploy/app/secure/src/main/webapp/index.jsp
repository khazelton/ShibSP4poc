<%@ page contentType="text/html;charset=UTF-8" import="java.util.*" %>
<!DOCTYPE html>
<html><head><title>SP4 PoC — protected</title>
<style>body{font-family:system-ui;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #999;padding:.25rem .6rem;text-align:left;vertical-align:top}th{background:#eee}code{font-size:.9em}</style>
</head><body>
<h1>/secure — identity as seen by the Jetty app</h1>
<p>This page is behind the SP v4 agent. Everything below arrived as HTTP headers set by Apache from the agent's env vars.</p>
<table>
<tr><th>Header</th><th>Value</th></tr>
<%
  List<String> names = Collections.list(request.getHeaderNames());
  Collections.sort(names, String.CASE_INSENSITIVE_ORDER);
  for (String n : names) {
    if (!n.toLowerCase().startsWith("x-shib") && !n.equalsIgnoreCase("x-remote-user")) continue;
%>
<tr><td><code><%= n %></code></td><td><code><%= request.getHeader(n) %></code></td></tr>
<% } %>
</table>
<h2>All request headers</h2>
<table>
<% for (String n : names) { %>
<tr><td><code><%= n %></code></td><td><code><%= request.getHeader(n) %></code></td></tr>
<% } %>
</table>
<p><a href="/public/">public page</a> · <a href="/Shibboleth.sso/Session">agent session</a> · <a href="/secure/callapi">call API as the app (Phase 3b)</a></p>
</body></html>
