// Sprint 6 lab starter script: Lumina Edge Functions
// Copy to lumina.js. Requirements: ../README.md section 4. Test: ../test_sprint06.sh
//
// Write the functions nginx.conf needs here, and list each one in the export at the bottom.

import crypto from 'crypto';

function key() {
	return process.env.LUMINA_KEY || '';
}

function hmac(msg, encoding) {
	return crypto.createHmac('sha256', key()).update(msg).digest(encoding);
}

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

function user(r) {
    var s = session(r);
    return s && s.sub ? String(s.sub) : '';
}

function info(r) {
    var s = session(r);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({ client: r.remoteAddress, user: s ? s.sub : null }) + '\n');
}

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

function pool(r) {
    var s = session(r);
    return s && s.plan == 'beta' ? 'beta' : 'stable';
}


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

function dropLength(r) {
    delete r.headersOut['Content-Length'];     // the body changes size
}

function maskCards(r, data, flags) {
    r.sendBuffer(data.replace(/\b(?:\d{4}[ -]?){3}(\d{4})\b/g, '****-****-****-$1'), flags);
}

export default { info, download, pool, orders, refreshRevoked, user, telemetry, dropLength, maskCards };
