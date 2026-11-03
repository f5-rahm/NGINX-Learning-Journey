// Sprint 6 Day 3 starting point: the script as Day 2 left it
// nginx calls the functions named in nginx.conf; each gets the request object, r.
import crypto from 'crypto';

var calls = 0;                     // a global: how long does it live?

// GET /edge/hello: answered by the edge, no origin involved
function hello(r) {
    r.headersOut['Content-Type'] = 'text/plain';
    r.return(200, 'Hello from ' + njs.engine + ' ' + njs.version
                  + ': ' + r.method + ' ' + r.uri + ' from ' + r.remoteAddress + '\n');
}

// GET /edge/count: adds one to the global and reports it
function count(r) {
    calls++;
    r.return(200, 'calls=' + calls + ' worker=' + ngx.worker_id + ' engine=' + njs.engine + '\n');
}

// js_set $client_lang: the first language the client asks for, or "en"
function lang(r) {
    var header = r.headersIn['Accept-Language'] || '';
    var first = header.split(',')[0].trim().toLowerCase().slice(0, 2);
    return /^[a-z]{2}$/.test(first) ? first : 'en';
}

// The session cookie's claims, decoded (not verified!)
function claims(r) {
    var token = r.variables.cookie_lumina_session;
    if (!token) {
        return null;
    }
    try {
        var payload = token.split('.')[1];
        return JSON.parse(Buffer.from(payload, 'base64url').toString());
    } catch (e) {
        r.warn('unreadable session cookie: ' + e.message);
        return null;
    }
}

// The session's claims if its signature is Lumina's and it hasn't expired; null otherwise
function session(r) {
    var token = r.variables.cookie_lumina_session;
    var key = process.env.LUMINA_KEY;
    if (!token || !key) {
        return null;
    }
    var parts = token.split('.');
    if (parts.length != 3) {
        return null;
    }
    var expected = crypto.createHmac('sha256', key).update(parts[0] + '.' + parts[1]).digest('base64url');
    if (expected != parts[2]) {
        return null;
    }
    var c = claims(r);
    if (!c || typeof c.exp != 'number' || c.exp <= Date.now() / 1000) {
        return null;
    }
    if (c.jti && ngx.shared.revoked.has(String(c.jti))) {
        return null;
    }
    return c;
}

// js_set $session_user: the sub of a valid session, or empty
function user(r) {
    var s = session(r);
    return s ? String(s.sub) : '';
}

// /downloads/: serve only links signed with HMAC-SHA256 over "<path>:<expires>"
function download(r) {
    var expires = r.args.expires;
    var sig = r.args.sig;
    var key = process.env.LUMINA_KEY;
    if (!key || !expires || !sig) {
        r.return(403);
        return;
    }
    var expected = crypto.createHmac('sha256', key).update(r.uri + ':' + expires).digest('hex');
    if (expected != sig) {
        r.return(403);
        return;
    }
    if (Number(expires) < Date.now() / 1000) {
        r.return(410);
        return;
    }
    r.internalRedirect('@files');
}

// js_header_filter: the body is about to change size, so drop the origin's length
function dropLength(r) {
    delete r.headersOut['Content-Length'];
}

// js_body_filter: replace card numbers with their last four digits
function maskCards(r, data, flags) {
    r.sendBuffer(data.replace(/\b(?:\d{4}[ -]?){3}(\d{4})\b/g, '****-****-****-$1'), flags);
}

// POST /api/orders: only a JSON object with an integer qty from 1 to 100 gets through
function orders(r) {
    var order = null;
    try {
        order = JSON.parse(r.requestText);
    } catch (e) {
        r.warn('order is not JSON: ' + e.message);
    }
    if (!order || typeof order != 'object' || !Number.isInteger(order.qty) || order.qty < 1 || order.qty > 100) {
        r.return(400, 'an order is a JSON object with an integer qty from 1 to 100\n');
        return;
    }
    r.internalRedirect('@app');
}

// js_periodic: copy the application's revocation list into the shared dictionary
async function refreshRevoked(s) {
    var list;
    try {
        var reply = await ngx.fetch('http://s6-origin:8016/_revoked');
        list = (await reply.json()).revoked;
    } catch (e) {
        ngx.log(ngx.WARN, 'revocation list not refreshed: ' + e.message);
        return;
    }
    var dict = ngx.shared.revoked;
    var listed = {};
    list.forEach(function (jti) {
        listed[jti] = true;
        dict.set(String(jti), '1');
    });
    dict.keys().forEach(function (k) {
        if (!listed[k]) {
            dict.delete(k);
        }
    });
}

// GET /edge/info: what the edge knows about this request
function info(r) {
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        client: r.remoteAddress,
        method: r.method,
        args: r.args,
        cookie_header: r.headersIn.Cookie || null,
        session: claims(r),
        verified: session(r),
        revoked: ngx.shared.revoked.keys(),
        worker: ngx.worker_id
    }) + '\n');
}

export default { hello, count, lang, info, user, download, maskCards, dropLength, orders, refreshRevoked };
