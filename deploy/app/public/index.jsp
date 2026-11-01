<%@ page contentType="text/html;charset=UTF-8" %>
<!DOCTYPE html>
<html><head><title>SP4 PoC — public</title><style>body{font-family:system-ui;margin:2rem}</style></head><body>
<h1>/public — no session required</h1>
<p>Served by Jetty behind the SP v4 agent (passive protection, <code>requireSession 0</code>).</p>
<p><a href="/secure/">Go to the protected page</a> — triggers login via the hub.</p>
</body></html>
