-- Proof-of-Player event sending

local serial = sys.get_env "SERIAL"
local device_id, setup_id, setup_secret
local json = require "json"
local hash = require "hash"
local clients = {}
local events = {}
local overflow = 0

local function log(msg, ...)
    print(string.format("[POP]: "..msg, ...))
end

util.json_watch("config.json", function(config)
    device_id = config.__metadata.device_id
    setup_id = config.__metadata.setup_id
    setup_secret = config.__metadata.secrets.setup
    log("device id is %d", device_id)
end)

local uuid = hash.uuid
if not uuid then -- fallback
    local uuid_counter = 1
    uuid = function()
        local seed = uuid_counter .. device_id .. setup_secret .. os.time()
        uuid_counter = uuid_counter + 1
        local h = hash.sha256_hex(seed)
        local hex = string.sub(h, 1, 32)
        hex = hex:sub(1, 12)
            .. "4"
            .. hex:sub(14, 16)
            .. string.format("%x", (tonumber(hex:sub(17, 17), 16) % 4) + 8)
            .. hex:sub(18)
        return string.format("%s-%s-%s-%s-%s",
            hex:sub(1, 8),
            hex:sub(9, 12),
            hex:sub(13, 16),
            hex:sub(17, 20),
            hex:sub(21, 32)
        )
    end
    log("using fallback uuid")
end

local function check_overflow()
    while #events > 16 do
        log("Warning: Overflowing event queue. No listener?")
        overflow = overflow + 1
        table.remove(events, 1)
    end
end

local function flush()
    while #events > 0 do
        local event = events[1]

        local sent = false
        for client, _ in pairs(clients) do
            sent = true
            node.client_write(client, event)
        end

        if not sent then
            return false
        end

        table.remove(events, 1)
    end
    return true
end

node.event("connect", function(client, prefix)
    if prefix ~= "::pop" then
        return
    end
    log("client %s connected", client)
    clients[client] = true
    node.client_write(client, json.encode{
        pop = "lua",
        version = 1,
        overflow = overflow,
    })
    overflow = 0
    flush()
end)

node.event("disconnect", function(client)
    if clients[client] then
        log("client %s disconnected", client)
        clients[client] = nil
    end
end)

local function submit(
    asset_id,
    asset_filename,
    duration,
    extra
)
    check_overflow()
    log("inserted playback of %s", asset_id)
    table.insert(events, json.encode{
        uuid = uuid(),
        asset = {
            id = asset_id,
            filename = asset_filename,
        },
        device = {
            id = device_id,
            serial = serial,
        },
        setup = {
            id = setup_id,
        },
        ts = math.floor(os.time()),
        duration = duration,
        extra = extra or {},
    })
    return flush()
end

return {
    submit = submit;
}
