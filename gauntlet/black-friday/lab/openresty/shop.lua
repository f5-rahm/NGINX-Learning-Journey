-- Northwind edge functions in Lua (ticket 8), the same logic as shop.js after ticket 7.
--
-- A member cookie is  nw_member=<id>.<expires>.<signature>
--   signature: hex HMAC-SHA256 of "<id>.<expires>" with the key in $SHOP_KEY
local hmac = require "resty.openssl.hmac"
local to_hex = require "resty.string".to_hex

local _M = {}
local KEY = os.getenv("SHOP_KEY") or ""          -- read once, at init (env SHOP_KEY in nginx.conf)

local function sign(msg)
    local h = assert(hmac.new(KEY, "sha256"))
    assert(h:update(msg))
    return to_hex(assert(h:final()))
end

-- The verified member ID, or "" for no cookie, a bad signature or an expired cookie
function _M.member()
    local v = ngx.var.cookie_nw_member
    if not v or KEY == "" then
        return ""
    end
    local id, exp, sig = v:match("^([a-z0-9-]+)%.(%d+)%.(%x+)$")
    if not id or #id > 32 or tonumber(exp) <= ngx.time() then
        return ""
    end
    if sign(id .. "." .. exp) ~= sig then
        return ""
    end
    return id
end

-- /ops/vip/<id>: POST adds a VIP, DELETE removes one
function _M.vip_admin()
    local id = ngx.var.uri:match("^/ops/vip/([a-z0-9-]+)$")
    if not id or #id > 32 then
        ngx.status = 400
        return ngx.say("bad member ID")
    end
    local method = ngx.req.get_method()
    if method == "POST" then
        ngx.shared.vip:set(id, "1")
        return ngx.exit(204)
    elseif method == "DELETE" then
        ngx.shared.vip:delete(id)
        return ngx.exit(204)
    end
    return ngx.exit(405)
end

return _M
