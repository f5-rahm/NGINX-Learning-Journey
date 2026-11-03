// Sprint 6 Day 1: the Lumina edge script
// nginx calls the functions named in nginx.conf; each gets the request object, r.

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

export default { hello, count };
