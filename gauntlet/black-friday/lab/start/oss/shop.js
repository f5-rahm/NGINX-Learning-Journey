// Northwind edge functions. Written for the default njs engine: var, function, no classes.
//
// A member cookie is  nw_member=<id>.<expires>.<signature>
//   id         lowercase letters, digits and dashes, up to 32
//   expires    Unix time
//   signature  hex HMAC-SHA256 of "<id>.<expires>" with the key in $SHOP_KEY
var crypto = require('crypto');

var ID = /^[a-z0-9-]{1,32}$/;

function key() {
    return process.env.SHOP_KEY || '';
}

// js_set $member: the verified member ID, or "" for no cookie, a bad signature or an expired cookie
function member(r) {
    var v = r.variables.cookie_nw_member;
    if (!v || !key()) {
        return '';
    }
    var p = v.split('.');
    if (p.length !== 3 || !ID.test(p[0]) || !(Number(p[1]) > Date.now() / 1000)) {
        return '';
    }
    var want = crypto.createHmac('sha256', key()).update(p[0] + '.' + p[1]).digest('hex');
    return want === p[2] ? p[0] : '';
}

export default { member };
