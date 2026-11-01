package org.aktis.sp4poc.api;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.jwk.source.JWKSourceBuilder;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.net.URL;
import java.util.Map;

/**
 * Phase 3b test resource server. Accepts a Google-signed ID token as Bearer, validates
 * signature (Google JWKS), issuer, audience and expiry, and echoes the claims as JSON.
 * Stands in for a campus API; with the campus OP only the JWKS URL and issuer change.
 */
@WebServlet("/echo")
public class EchoServlet extends HttpServlet {

    private static final String API_AUDIENCE = env("API_AUDIENCE", "https://sp4-poc-api.localtest");
    private static final String GOOGLE_JWKS  = "https://www.googleapis.com/oauth2/v3/certs";

    private JWKSource<SecurityContext> jwks;

    @Override
    public void init() {
        try {
            // Caches keys, refreshes on unknown kid, rate-limited.
            jwks = JWKSourceBuilder.create(new URL(GOOGLE_JWKS)).build();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json;charset=UTF-8");
        String auth = req.getHeader("Authorization");
        if (auth == null || !auth.startsWith("Bearer ")) {
            fail(resp, 401, "missing bearer token");
            return;
        }
        // ?expectAud= lets the caller demonstrate an audience mismatch without a second client.
        String expectAud = req.getParameter("expectAud") != null ? req.getParameter("expectAud") : API_AUDIENCE;
        try {
            // Signature + key selection (RS256 against Google's JWKS). The processor's default
            // claims verifier only checks exp/nbf; iss/aud/sub are checked explicitly below so
            // the rules are visible in the PoC.
            DefaultJWTProcessor<SecurityContext> proc = new DefaultJWTProcessor<>();
            proc.setJWSKeySelector(new JWSVerificationKeySelector<>(JWSAlgorithm.RS256, jwks));
            JWTClaimsSet claims = proc.process(auth.substring(7).trim(), null);

            String iss = claims.getIssuer();
            if (!"https://accounts.google.com".equals(iss) && !"accounts.google.com".equals(iss)) {
                fail(resp, 401, "unexpected issuer " + iss);
                return;
            }
            if (claims.getAudience() == null || !claims.getAudience().contains(expectAud)) {
                fail(resp, 401, "audience mismatch: token aud=" + claims.getAudience() + ", expected " + expectAud);
                return;
            }
            if (claims.getSubject() == null || claims.getExpirationTime() == null) {
                fail(resp, 401, "missing sub or exp");
                return;
            }
            StringBuilder sb = new StringBuilder("{\n  \"ok\": true,\n  \"validated_against\": {\"jwks\": \"")
                    .append(GOOGLE_JWKS).append("\", \"aud\": \"").append(expectAud).append("\"},\n  \"claims\": {\n");
            boolean first = true;
            for (Map.Entry<String, Object> e : claims.getClaims().entrySet()) {
                if (!first) sb.append(",\n");
                first = false;
                sb.append("    \"").append(e.getKey()).append("\": \"").append(String.valueOf(e.getValue()).replace("\"", "\\\"")).append("\"");
            }
            sb.append("\n  }\n}\n");
            resp.getWriter().print(sb);
        } catch (Exception e) {
            String where = e.getStackTrace().length > 0 ? " @" + e.getStackTrace()[0] : "";
            fail(resp, 401, e.getClass().getSimpleName() + ": " + e.getMessage() + where);
        }
    }

    private static void fail(HttpServletResponse resp, int code, String msg) throws IOException {
        resp.setStatus(code);
        resp.setHeader("WWW-Authenticate", "Bearer");
        resp.getWriter().print("{\"ok\": false, \"error\": \"" + msg.replace("\"", "'") + "\"}\n");
    }

    private static String env(String k, String dflt) {
        String v = System.getenv(k);
        return (v == null || v.isBlank()) ? dflt : v;
    }
}
