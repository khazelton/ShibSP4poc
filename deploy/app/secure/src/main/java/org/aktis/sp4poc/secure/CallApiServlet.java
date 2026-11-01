package org.aktis.sp4poc.secure;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.util.JSONObjectUtils;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.io.PrintWriter;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.interfaces.RSAPrivateKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.text.ParseException;
import java.time.Instant;
import java.util.Base64;
import java.util.Date;
import java.util.Map;

/**
 * Phase 3b: the app obtains a token "as itself" and calls the test API with it.
 *
 * Google has no client_credentials grant; the equivalent is RFC 7523 JWT-bearer with a
 * service-account key plus a target_audience claim, which yields a Google-signed ID token
 * whose aud is the API. (With the campus OP this whole class collapses to one
 * client_credentials POST; see docs/poc-outline.md Phase 3b.)
 *
 * No Google client library on purpose: the mechanics are the point of the PoC.
 */
@WebServlet("/callapi")
public class CallApiServlet extends HttpServlet {

    private static final String SA_KEY_FILE   = env("SA_KEY_FILE",   "/var/lib/jetty/secrets/sa.json");
    private static final String API_AUDIENCE  = env("API_AUDIENCE",  "https://sp4-poc-api.localtest");
    private static final String API_URL       = env("API_URL",       "http://localhost:8081/api/echo");
    private static final String GOOGLE_TOKEN  = "https://oauth2.googleapis.com/token";

    private final HttpClient http = HttpClient.newHttpClient();

    // Simple cache: reuse the ID token until shortly before it expires.
    private volatile String cachedToken;
    private volatile Instant cachedExp = Instant.EPOCH;

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        resp.setContentType("text/html;charset=UTF-8");
        PrintWriter out = resp.getWriter();
        out.println("<!DOCTYPE html><html><head><title>SP4 PoC — call API</title>"
                + "<style>body{font-family:system-ui;margin:2rem}pre{background:#f4f4f4;padding:.6rem;overflow:auto}"
                + "table{border-collapse:collapse}td,th{border:1px solid #999;padding:.25rem .6rem;text-align:left}th{background:#eee}</style></head><body>");
        out.println("<h1>/secure/callapi — app calls the API as itself</h1>");
        out.println("<p>User identity (from the agent): <code>" + esc(req.getHeader("X-Shib-Mail")) + "</code> — "
                + "but the API call below carries the <em>app's</em> token, not the user's.</p>");
        try {
            boolean fromCache = cachedToken != null && Instant.now().isBefore(cachedExp.minusSeconds(60));
            String idToken = fromCache ? cachedToken : fetchIdToken();
            SignedJWT jwt = SignedJWT.parse(idToken);
            JWTClaimsSet c = jwt.getJWTClaimsSet();
            out.println("<h2>1. Token from Google (" + (fromCache ? "cached" : "fresh") + ")</h2>");
            out.println("<table><tr><th>claim</th><th>value</th></tr>");
            for (Map.Entry<String, Object> e : c.getClaims().entrySet()) {
                out.println("<tr><td><code>" + esc(e.getKey()) + "</code></td><td><code>" + esc(String.valueOf(e.getValue())) + "</code></td></tr>");
            }
            out.println("</table>");
            out.println("<p>raw (truncated): <code>" + esc(idToken.substring(0, Math.min(40, idToken.length()))) + "…</code></p>");

            HttpRequest apiReq = HttpRequest.newBuilder(URI.create(API_URL))
                    .header("Authorization", "Bearer " + idToken)
                    .GET().build();
            HttpResponse<String> apiResp = http.send(apiReq, HttpResponse.BodyHandlers.ofString());
            out.println("<h2>2. API response (" + apiResp.statusCode() + ") from <code>" + esc(API_URL) + "</code></h2>");
            out.println("<pre>" + esc(apiResp.body()) + "</pre>");

            // Negative demo: same token, wrong audience expected by the API
            HttpRequest badReq = HttpRequest.newBuilder(URI.create(API_URL + "?expectAud=https://someone-else.example"))
                    .header("Authorization", "Bearer " + idToken).GET().build();
            HttpResponse<String> badResp = http.send(badReq, HttpResponse.BodyHandlers.ofString());
            out.println("<h2>3. Negative: API told to expect a different audience → " + badResp.statusCode() + "</h2>");
            out.println("<pre>" + esc(badResp.body()) + "</pre>");
        } catch (Exception ex) {
            resp.setStatus(500);
            out.println("<h2>Error</h2><pre>" + esc(ex.toString()) + "</pre>");
        }
        out.println("<p><a href=\"/secure/\">back</a></p></body></html>");
    }

    /** RFC 7523 JWT-bearer with Google's target_audience extension → ID token. */
    private String fetchIdToken() throws IOException, InterruptedException, JOSEException, ParseException, java.security.GeneralSecurityException {
        Map<String, Object> sa = JSONObjectUtils.parse(Files.readString(Path.of(SA_KEY_FILE)));
        String email = (String) sa.get("client_email");
        String pem = (String) sa.get("private_key");
        String b64 = pem.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "").replaceAll("\\s", "");
        RSAPrivateKey key = (RSAPrivateKey) KeyFactory.getInstance("RSA")
                .generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(b64)));

        Instant now = Instant.now();
        JWTClaimsSet assertion = new JWTClaimsSet.Builder()
                .issuer(email).subject(email)
                .audience(GOOGLE_TOKEN)
                .issueTime(Date.from(now))
                .expirationTime(Date.from(now.plusSeconds(600)))
                .claim("target_audience", API_AUDIENCE)
                .build();
        SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256)
                .keyID((String) sa.get("private_key_id")).build(), assertion);
        jwt.sign(new RSASSASigner(key));

        String form = "grant_type=" + URLEncoder.encode("urn:ietf:params:oauth:grant-type:jwt-bearer", StandardCharsets.UTF_8)
                + "&assertion=" + jwt.serialize();
        HttpRequest tokenReq = HttpRequest.newBuilder(URI.create(GOOGLE_TOKEN))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form)).build();
        HttpResponse<String> tokenResp = http.send(tokenReq, HttpResponse.BodyHandlers.ofString());
        if (tokenResp.statusCode() != 200) {
            throw new IOException("Google token endpoint returned " + tokenResp.statusCode() + ": " + tokenResp.body());
        }
        String idToken = (String) JSONObjectUtils.parse(tokenResp.body()).get("id_token");
        cachedToken = idToken;
        cachedExp = SignedJWT.parse(idToken).getJWTClaimsSet().getExpirationTime().toInstant();
        return idToken;
    }

    private static String env(String k, String dflt) {
        String v = System.getenv(k);
        return (v == null || v.isBlank()) ? dflt : v;
    }

    private static String esc(String s) {
        if (s == null) return "(null)";
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }
}
