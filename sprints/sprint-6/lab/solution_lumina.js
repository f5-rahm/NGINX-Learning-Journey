// Sprint 6 lab reference script: Lumina Edge Functions
// Written for the default njs engine: var, function, no classes, no destructuring.
import crypto from 'crypto';

// --- Keys and signatures ---------------------------------------------------

function key() {
    return process.env.LUMINA_KEY || '';      // needs "env LUMINA_KEY;" in the main context
}

function hmac(msg, encoding) {
    return crypto.createHmac('sha256', key()).update(msg).digest(encoding);
}

// --- Sessions ----------------------------------------------------------------

// The session's claims if the lumina_session cookie is a valid, unexpired, unrevoked HS256 JWT;
// null otherwise. Never throws: a broken cookie is just "no session".
function session(r) {
    var tok = r.variables.cookie_lumina_session;
    if (!tok || !key()) {
        return null;
    }
    var parts = tok.split('.');
    if (parts.length != 3) {
        return null;
    }
    try {
        var head = JSON.parse(Buffer.from(parts[0], 'base64url').toString());
        if (head.alg != 'HS256') {
            return null;                       // never let the token choose the algorithm
        }
        if (hmac(parts[0] + '.' + parts[1], 'base64url') != parts[2]) {
            return null;
        }
        var claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
        if (typeof claims.exp != 'number' || claims.exp <= Date.now() / 1000) {
            return null;
        }
        if (claims.jti && ngx.shared.revoked.has(String(claims.jti))) {
            return null;
        }
        return claims;
    } catch (e) {
        return null;
    }
}

// js_set $session_user: the sub of a valid session, or empty (proxy_set_header then sends nothing)
function user(r) {
    var s = session(r);
    return s && s.sub ? String(s.sub) : '';
}

// js_set $pool: the upstream for this request
function pool(r) {
    var s = session(r);
    return s && s.plan == 'beta' ? 'beta' : 'stable';
}

// --- Revocation list (js_periodic, shared dict) ----------------------------

async function refreshRevoked(s) {
    var list;
    try {
        var resp = await ngx.fetch('http://s6-origin:8016/_revoked');
        list = (await resp.json()).revoked;
    } catch (e) {
        ngx.log(ngx.WARN, 'revocation list not refreshed, keeping the last one: ' + e.message);
        return;
    }
    var dict = ngx.shared.revoked;
    var want = {};
    list.forEach(function (jti) { want[jti] = true; dict.set(String(jti), '1'); });
    dict.keys().forEach(function (k) { if (!want[k]) { dict.delete(k); } });
}

// --- /edge/info ---------------------------------------------------------------

function info(r) {
    var s = session(r);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({ client: r.remoteAddress, user: s ? s.sub : null }) + '\n');
}

// --- Signed download links ----------------------------------------------------

function download(r) {
    var expires = r.args.expires;
    var sig = r.args.sig;
    if (!expires || !sig || !/^[0-9]+$/.test(expires) || hmac(r.uri + ':' + expires, 'hex') != sig) {
        r.return(403);
        return;
    }
    if (Number(expires) < Date.now() / 1000) {
        r.return(410);
        return;
    }
    r.internalRedirect('@files');
}

// --- Order validation -----------------------------------------------------------

function orders(r) {
    var body;
    try {
        body = JSON.parse(r.requestText || '');
    } catch (e) {
        body = null;
    }
    var ok = body !== null && typeof body == 'object' && !Array.isArray(body)
             && Number.isInteger(body.qty) && body.qty >= 1 && body.qty <= 100;
    if (!ok) {
        r.headersOut['Content-Type'] = 'application/json';
        r.return(400, '{"error": "an order is a JSON object with an integer qty from 1 to 100"}\n');
        return;
    }
    r.internalRedirect('@app');
}

// --- Card masking (header + body filter) ------------------------------------

function dropLength(r) {
    delete r.headersOut['Content-Length'];     // the body changes size
}

function maskCards(r, data, flags) {
    r.sendBuffer(data.replace(/\b(?:\d{4}[ -]?){3}(\d{4})\b/g, '****-****-****-$1'), flags);
}

// --- Telemetry (stream) -----------------------------------------------------------

function telemetry(s) {
    var buf = '';
    s.on('upload', function (data, flags) {
        buf += data;
        var nl = buf.indexOf('\n');
        if (nl == -1) {
            if (buf.length > 512 || flags.last) {
                s.deny();
            }
            return;
        }
        var f = buf.slice(0, nl).trim().split(' ');
        if (f.length == 3 && f[0] == 'HELLO' && key() && f[2] == hmac(f[1], 'hex').slice(0, 16)) {
            s.allow();
        } else {
            s.deny();
        }
    });
}

export default { user, pool, refreshRevoked, info, download, orders, dropLength, maskCards, telemetry };
