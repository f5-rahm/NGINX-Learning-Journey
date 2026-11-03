// Sprint 6 Day 1: the Lumina edge script
// nginx calls the functions named in nginx.conf; each gets the request object, r.

var calls = 0;                     // a global: how long does it live?

// GET /edge/hello: answered by the edge, no origin involved
function hello(r) {
    r.headersOut['Content-Type'] = 'text/plain';
    r.return(200, 'Hi from ' + njs.engine + ' ' + njs.version
                  + ': ' + r.method + ' ' + r.uri + ' from ' + r.remoteAddress + '\n');
}

// GET /edge/count: adds one to the global and reports it
function count(r) {
    calls++; 
    r.return(200, 'calls=' + calls + ' worker=' + ngx.worker_id + ' engine=' + njs.engine + '\n');
}

// js_set $client_lang: the first language the client asks for, or "en"
function lang(r) {
    ngx.log(ngx.WARN, 'lang() called for ' + r.uri);
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

// GET /edge/info: what the edge knows about this request
function info(r) {
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        client: r.remoteAddress,
        method: r.method,
        args: r.args,
        cookie_header: r.headersIn.Cookie || null,
        session: claims(r)
    }) + '\n');
}

export default { hello, count, lang, info };

