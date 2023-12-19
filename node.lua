gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
util.no_globals()

local MAX_CONFIG_STATES = 5

local matrix = require "matrix2d"
local rpc = require "rpc"
local json = require "json"
local loader = require "loader"
local helpers = require "helpers"
local easing = require "easing"
local scissors = sys.get_ext "scissors"
local font = resource.load_font "font.ttf"
local black = resource.create_colored_texture(0, 0, 0, 1)
local red = resource.create_colored_texture(1, 0, 0, 1)
local green = resource.create_colored_texture(0, 1, 0, 1)

local py = rpc.create()

local wall_state = {wall_time={}, os={}, playback={}}
local show_debug_end = 0
local alternative_idx = 'default'
local max_stretch = 1
local audio = true
local fuse = "never"
local use_overlay = true
local reveal_t = 0
local revealer = "instant"
local overlay_name
local full_quad = helpers.Quad(0, 0, 100, 100)
local wall_pos = full_quad
local wall_scale_up = 'stretch'
local display_pos = full_quad

local function log(fmt, ...)
    print(string.format("[player] "..fmt, ...))
end

local function tags_from_string(tags)
    return helpers.list_to_set(
        tags and helpers.str_split(tags, ",") or {}
    )
end

-- Singletons ---------------------------------------------------------

local function SharedTime()
    local local_diff = 0
    local target_diff = 0
    local jumped = false
    local local_time = 0

    local function update(shared_time, os_sent_time)
        -- compensate delay caused by info-beamer only handling
        -- TCP events every frame. The packet includes the timestamp
        -- of when the packet was sent, so we can calculate and
        -- compensate the delay.
        local send_delay = os.time() - os_sent_time
        print('time updated', shared_time)
        target_diff = shared_time + send_delay - sys.now()
    end

    local function tick()
        if math.abs(target_diff - local_diff) > 0.3 then
            print('time jump')
            jumped = true
            local_diff = target_diff
        else
            jumped = false
        end
        local_diff = local_diff * 0.95 + target_diff * 0.05
        local_time = local_diff + sys.now()
        wall_state.wall_time.time = local_time
        wall_state.wall_time.diff = string.format("%.5f", target_diff - local_diff)
    end

    local function get()
        return local_time, jumped
    end

    return {
        update = update;
        tick = tick;
        get = get;
    }
end

local function PlayerStack()
    local active_layers = {}
    local active_layer_by_id = {}
    local active_ctx = {}

    local next_layers = {}
    local next_layer_by_id = {}
    local next_ctx = {}

    local need_disposal = {}

    local function init_player(player, ...)
        player.ctx.reveal_in = true
        player.ctx.reveal_out = true
        player:init(...)
        return player
    end
    local function merge_player(old_player, new_player)
        local can_reuse = (
            -- ensure that player fusing is allowed
            (
                -- if only for primary, then if the layer is the
                -- primary layer.
                fuse == "primary" and new_player.ctx.is_primary or
                
                -- If overlay, then only fuse if not primary
                fuse == "overlays" and not new_player.ctx.is_primary or

                -- If fusing is generally enabled
                fuse == "all" or

                -- If fallback playing
                (old_player.ctx.fallback and new_player.ctx.fallback)
            )

            -- and that the playlist didn't just wrap around:
            -- we won't fuse those players as they might then
            -- run endlessly, thereby potentially going out of
            -- sync when running for a long time.
            and (new_player.allow_wrap or not new_player.ctx.wrapped)

            -- and the player itself produces a merge_info
            -- that is compatible with the following player.
            and helpers.dict_shallow_equal(
                old_player:merge_info(),
                new_player:merge_info()
            )
        )

        table.insert(need_disposal, old_player)
        if can_reuse then
            print('reusing player')
            local new_player = init_player(new_player, old_player:merge_forward())
            old_player.ctx.reveal_out = false
            new_player.ctx.reveal_in = false
            return new_player
        else
            print('reloading player')
            return init_player(new_player)
        end
    end

    local function switch()
        if #next_layers == 0 then
            print("nothing to switch to. ignoring and waiting for next preload")
            return
        end
        for _, old_player in ipairs(need_disposal) do
            old_player:dispose()
        end

        active_layers = next_layers
        active_layer_by_id = next_layer_by_id
        active_ctx = next_ctx
        active_ctx.started = sys.now()
        active_ctx.ends = active_ctx.started + active_ctx.duration

        for _, player in ipairs(active_layers) do
            player.ctx.started = active_ctx.started
            player.ctx.ends = player.ctx.started + player.ctx.duration
            player.ctx.now = sys.now()
            player.ctx.progress = 0
            player.ctx.reveal = 0
            player:switch()
        end

        next_layers = {}
        next_layer_by_id = {}
        next_ctx = {}
        need_disposal = {}
    end

    local function update_begin(ctx)
        if #next_layers > 0 then -- update called without using switch
            print "forcing switch"
            switch()
        end

        next_layers = {}
        next_layer_by_id = {}
        next_ctx = ctx
    end

    local function update_add_layer(id, player)
        local function add_layer(id, player)
            table.insert(next_layers, player)
            next_layer_by_id[id] = #next_layers
        end

        local existing_layer_idx = active_layer_by_id[id]
        if existing_layer_idx then
            add_layer(id, merge_player(
                active_layers[existing_layer_idx],
                player
            ))
        else
            add_layer(id, init_player(player))
        end
    end

    local function update_commit()
        for old_id, old_idx in pairs(active_layer_by_id) do
            if not next_layer_by_id[old_id] then
                local old_player = active_layers[old_idx]
                table.insert(need_disposal, old_player)
            end
        end
    end

    local function draw(canvas)
        local now = sys.now()
        local easer = ({
            linear = easing.linear,
            inOutQuad = easing.inOutQuad,
            outExpo = easing.outExpo,
            instant = function()
                return 1
            end,
        })[revealer]

        local t_in = reveal_t
        local t_out = reveal_t

        local from_start = now - active_ctx.started
        local until_ends = math.max(0, active_ctx.ends - now)

        for idx, player in ipairs(active_layers) do
            player.ctx.now = now
            player.ctx.progress = math.max(0, math.min(1, 
                1 / player.ctx.duration * (sys.now() - player.ctx.started)
            ))
            player.ctx.reveal = math.min(
                player.ctx.reveal_in and easer(
                    math.min(from_start, t_in),
                    0,
                    1,
                    t_in
                ) or 1,
                player.ctx.reveal_out and easer(
                    math.min(until_ends, t_out),
                    0,
                    1,
                    t_out
                ) or 1
            )
        end
        local layer_quads = {}
        for idx = #active_layers, 1, -1 do
            local player = active_layers[idx]
            layer_quads[idx] = player:layout(canvas)
        end
        for idx, player in ipairs(active_layers) do
            player:draw(canvas, layer_quads[idx])
        end
    end

    local function get_ctx()
        return active_ctx
    end

    return {
        draw = draw,
        switch = switch,
        update_begin = update_begin,
        update_add_layer = update_add_layer,
        update_commit = update_commit,
        get_ctx = get_ctx,
    }
end

local function Display()
    local rotation = 0
    local is_portrait = false
    local base_transform
    local transform
    local virtual_w, virtual_h, w, h

    local function round(v)
        return math.floor(v+.5)
    end

    local function update_placement(new_rotation, display_pos, new_virtual_w, new_virtual_h)
        rotation = new_rotation

        virtual_w = new_virtual_w or NATIVE_WIDTH
        virtual_h = new_virtual_h or NATIVE_HEIGHT

        is_portrait = rotation == 90 or rotation == 270

        if is_portrait then
            virtual_w, virtual_h = virtual_h, virtual_w
        end

        gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

        local x1, y1, x2, y2 = display_pos:coords()
        base_transform = matrix.trans(
                            NATIVE_WIDTH * x1 / 100,
                            NATIVE_HEIGHT * y1 / 100
                         ) *
                         matrix.scale(
                             (x2-x1) / 100,
                             (y2-y1) / 100
                         )

        if rotation == 0 then
            -- nothing to do
        elseif rotation == 90 then
            base_transform = base_transform *
                             matrix.trans(NATIVE_WIDTH, 0) *
                             matrix.rotate_deg(rotation)
        elseif rotation == 180 then
            base_transform = base_transform *
                             matrix.trans(NATIVE_WIDTH, NATIVE_HEIGHT) *
                             matrix.rotate_deg(rotation)
        elseif rotation == 270 then
            base_transform = base_transform *
                             matrix.trans(0, NATIVE_HEIGHT) *
                             matrix.rotate_deg(rotation)
        else
            return error(string.format("cannot rotate by %d degree", rotation))
        end
    end

    local function frame_update(frame_transform)
        transform = transform * frame_transform
        gl.ortho()
        matrix.apply_gl(transform)

        local tx1, ty1 = transform(0, 0)
        local tx2, ty2 = transform(w, h)
        local x1, y1, x2, y2 = round(math.min(tx1, tx2)),
                               round(math.min(ty1, ty2)),
                               round(math.max(tx1, tx2)),
                               round(math.max(ty1, ty2))

        if x1 ~= 0 or y1 ~= 0 or x2 ~= NATIVE_WIDTH or y2 ~= NATIVE_HEIGHT then
            scissors.set(x1, y1, x2, y2)
        end
    end

    local function frame_init(pos)
        transform = base_transform

        -- resize virtual size into scaled total canvas
        w, h = virtual_w, virtual_h

        local x1, y1, x2, y2 = pos:coords()

        local total_w = x2 - x1
        local total_h = y2 - y1
        if wall_scale_up == 'aspect_up' then
            if total_w > total_h then
                w = w * (total_w / total_h)
            else
                h = h * (total_h / total_w)
            end
        elseif wall_scale_up == 'aspect_down' then
            if total_w > total_h then
                h = h / (total_w / total_h)
            else
                w = w / (total_h / total_w)
            end
        end

        if not is_portrait then
            transform = transform *
                        matrix.scale(NATIVE_WIDTH  / w,
                                     NATIVE_HEIGHT / h)
        else
            transform = transform *
                        matrix.scale(NATIVE_HEIGHT / w,
                                     NATIVE_WIDTH /  h)
        end

        wall_state.canvas_size = string.format("%d x %d", w, h)

        local x1, y1, x2, y2 = pos:coords()
        frame_update(
            matrix.trans(w * x1 / 100, h * y1 / 100) *
            matrix.scale((x2-x1) / 100, (y2-y1) / 100)
        )
    end

    local function draw_video(vid, x1, y1, x2, y2)
        local tx1, ty1 = transform(x1, y1)
        local tx2, ty2 = transform(x2, y2)
        local x1, y1, x2, y2 = round(math.min(tx1, tx2)),
                               round(math.min(ty1, ty2)),
                               round(math.max(tx1, tx2)),
                               round(math.max(ty1, ty2))
        return vid:place(x1, y1, x2, y2, rotation)
    end

    local function draw_image(img, x1, y1, x2, y2, alpha)
        return img:draw(x1, y1, x2, y2, alpha)
    end

    local function size()
        return w, h
    end

    update_placement(0, full_quad)

    return {
        update_placement = update_placement;
        draw_image = draw_image;
        draw_video = draw_video;
        is_portrait = function() return is_portrait end;
        size = size;
        frame_init = frame_init;
        frame_update = frame_update;
    }
end

local SharedTime = SharedTime()
local Display = Display()
local PlayerStack = PlayerStack()

-- Debugging ----------------------------------------------------

util.data_mapper{
    ["debug/update"] = function(raw)
        for k, v in pairs(json.decode(raw)) do
            wall_state[k] = v
        end
    end;

    ["debug/show"] = function(duration)
        show_debug_end = sys.now() + tonumber(duration)
    end;

    ["trigger"] = function(trigger_cmd)
        py.trigger(trigger_cmd)
    end;

    ["sys/cec/key"] = function(key)
      if key == 'setup-menu' then
          show_debug_end = sys.now() + 90
      elseif key == 'exit' then
          show_debug_end = 0
      end
    end;

    ["sys/syncer/progress"] = function(progress)
        wall_state.os.updating = true
        wall_state.os.update_progress = helpers.progress_bar_string(tonumber(progress))
    end;

    ["sys/syncer/updating"] = function(active)
        wall_state.os.updating = active == "1"
        wall_state.os.update_progress = ''
    end;

    ["sys/syncer/status"] = function(new_status)
        wall_state.os.status = new_status
    end;
}

local function debug_overlay(ctx)
    scissors.disable()
    gl.ortho()
    black:draw(0, 0, WIDTH, HEIGHT, 0.6)
    local time = SharedTime.get()
    local x = (time * 800) % WIDTH
    local y = (time * 800) % HEIGHT 
    red:draw(0, y-10, WIDTH, y+10, 0.5)
    green:draw(x-10, 0, x+10, HEIGHT, 0.5)

    local x, y = 50, 50
    local function write(xx, text, r,g,b,a, size)
        size = size or 20
        font:write(x+xx, y, text, size, r,g,b,a)
        y = y + size + 3
        if y > HEIGHT - 30 then
            x = x + 400
            y = 50
        end
    end
    local function write_obj(depth, obj)
        local keys = {}
        for k, v in pairs(obj) do
            keys[#keys+1] = k
        end
        table.sort(keys)
        for idx, k in ipairs(keys) do
            local v = obj[k]
            if type(v) == "table" then
                if next(v) then
                    y = y + 3
                    write(depth*30, k, 1,1,1,1)
                    write_obj(depth+1, v)
                    y = y + 3
                end
            else
                write(depth*30, string.format("%s    %s", k, v), 1,0.5,0.5,1)
            end
        end
    end
    write(0, "[DEBUG]", 1,1,1,1, 40)
    write(0, "", 0,0,0,0)
    if wall_state.peer and wall_state.peer.is_leader then
        local num_peers = wall_state.peers and #wall_state.peers or 0
        write(0, string.format("Leader device %d controlling group of %d devices", wall_state.config.device_id, num_peers), 1,1,1,1)
    else
        local leader_id = wall_state.leader and wall_state.leader.device_id or '<unknown>'
        write(0, string.format("Follower device %d, controlled by %s", wall_state.config.device_id, leader_id), 1,1,1,1)
    end
    write(0, "", 0,0,0,0)

    local playback = {
        ctx = ctx,
        now = sys.now(),
        overtime = sys.now() > ctx.started + ctx.duration,
    }
    if ctx.started then
        playback.progress = helpers.progress_bar_string(1 / ctx.duration * (sys.now() - ctx.started))
    end
    write_obj(0, {playback = playback})
    write_obj(0, wall_state)
end

-- Fallback wrapper ----------------------------------------------

local FallbackImage = helpers.create_class{
    construct = function(self)
        self.asset = nil
        self.asset_name = nil
    end;

    update = function(self, new_asset_name)
        if self.asset and new_asset_name == self.asset_name then
            return
        end
        if self.asset then
            self.asset:dispose()
        end
        self.asset_name = new_asset_name
        self.asset = resource.load_image{
            file = new_asset_name,
        }
    end;

    draw = function(self, ...)
        return self.asset:draw(...)
    end;

    state = function(self, ...)
        return self.asset:state(...)
    end;

    dispose = function(self)
        -- nop
    end;
}

local FallbackH = FallbackImage()
local FallbackV = FallbackImage()


-- Config loading ----------------------------------------------------

local config_by_hash = {}
local loaded_configs = {} -- loaded revs in oldest->newest order

local function add_loaded_config(config_hash, config)
    for idx, existing_hash in ipairs(loaded_configs) do
        if existing_hash == config_hash then
            table.remove(loaded_configs, idx)
            config_by_hash[existing_hash] = nil
            break
        end
    end
    if #loaded_configs >= MAX_CONFIG_STATES then
        local removed_hash = table.remove(loaded_configs, 1)
        config_by_hash[removed_hash] = nil
    end
    table.insert(loaded_configs, config_hash)
    config_by_hash[config_hash] = config
    wall_state.playable_configs = loaded_configs
end

local function create_player_info_from_item(asset, child_config, extra_tags)
    return {
        asset_type = asset.type,
        asset_id = asset.asset_id,
        filename = asset.filename,
        tags = helpers.set_union(
            helpers.list_to_set(asset.tags),
            extra_tags or {}
        ),
        file = asset.type ~= "child" and resource.open_file(asset.asset_name) or nil,
        child_config = child_config,
    }
end

local function load_playlist(playlist_items)
    local playlist = {}
    for _, item in ipairs(playlist_items) do
        local alternatives = {
            default = {
                create_player_info_from_item(
                    item.asset,
                    item.child_config,
                    tags_from_string(item.extra_tags)
                )},
            [1]={}, [2]={}, [3]={}, [4]={},
            [5]={}, [6]={}, [7]={}, [8]={},
        }
        for _, alt_item in ipairs(item.alternatives or {}) do
            if alt_item.alt_type == "item" then
                table.insert(
                    alternatives[alt_item.alternative_idx],
                    create_player_info_from_item(
                        alt_item.asset,
                        alt_item.child_config,
                        tags_from_string(item.extra_tags)
                    )
                )
            else
                for _, alt_playlist_item in ipairs(alt_item.playlist) do
                    pp(alt_playlist_item)
                    table.insert(
                        alternatives[alt_item.alternative_idx],
                        create_player_info_from_item(
                            alt_playlist_item.asset,
                            {},
                            tags_from_string(item.extra_tags)
                        )
                    )
                end
            end
        end
        table.insert(playlist, {
            slot_type = item.slot_type,
            alternatives = alternatives,
        })
    end
    return playlist
end

local function load_overlay_groups(overlay_groups)
    local loaded_overlay_groups = {}
    for _, overlay_group in ipairs(overlay_groups) do
        local loaded_overlay_group = {
            group_id = overlay_group._id,
            conditions = overlay_group.conditions,
            overlays = {},
        }
        for _, item in ipairs(overlay_group.overlays) do
            table.insert(loaded_overlay_group.overlays, {
                overlay_id = item._id,
                player_info = create_player_info_from_item(
                    item.asset,
                    item.child_config
                )
            })
        end
        table.insert(loaded_overlay_groups, loaded_overlay_group)
    end
    return loaded_overlay_groups
end

util.json_watch("config.json", function(config)
    wall_state.config = {
        setup_id = config.__metadata.setup_id,
        device_id = config.__metadata.device_id,
    }

    FallbackH:update(config.fallback_h.asset_name)
    FallbackV:update(config.fallback_v.asset_name)

    local device_data = config.__metadata.device_data
    local config_hash = config.__metadata.config_hash

    local wall = device_data.wall
    if wall then
        wall_pos = helpers.Quad(
            wall.x1 or 0, wall.y1 or 0,
            wall.x2 or 100, wall.y2 or 100
        )
        wall_scale_up = wall.scale_up or 'aspect_down'
    else
        wall_pos = full_quad
        wall_scale_up = 'stretch'
    end

    local display = device_data.display
    if display then
        display_pos = helpers.Quad(
            display.x1 or 0, display.y1 or 0,
            display.x2 or 100, display.y2 or 100
        )
    else
        display_pos = full_quad
    end

    max_stretch = config.max_stretch
    audio = config.audio
    fuse = config.fuse
    reveal_t = config.reveal[1]
    revealer  = config.reveal[2]
    alternative_idx = device_data.alternative_idx or 'default'

    local rotation = device_data.rotation or 0

    local virtual_w, virtual_h
    local virtual_resolution = config.virtual_resolution
    if virtual_resolution then
        virtual_w, virtual_h = virtual_resolution[1], virtual_resolution[2]
    end

    Display.update_placement(rotation, display_pos, virtual_w, virtual_h)

    wall_state.screen = {
        alternative_idx = alternative_idx,
        rotation = rotation,
        placement = {
            wall = wall_pos:as_table(),
            display = display_pos:as_table(),
        },
    }

    add_loaded_config(config_hash, {
        playlist = load_playlist(config.playlist),
        overlay_groups = load_overlay_groups(config.overlay_groups or {}),
    })

    log('config state: %s', config_hash)
    node.gc()
end)

-- local function submit_pop(item, duration)
--     py.submit_pop({
--         play_start = os.time(),
--         duration = duration,
--         asset_id = item.asset_id,
--         asset_filename = item.asset_filename,
--     })
-- end

-- Child nodes -------------------------------------------------------

local PluginLoader = loader.setup "zz-plugin.lua"

function PluginLoader.before_load(child, api)
    api.wall_time = SharedTime.get
end

-- Players ---------------------------------------------------------

local Player = helpers.create_class{
    allow_wrap = true;
    construct = function(self, ctx)
        self.ctx = ctx
    end;
    merge_info = function()
    end;
    init = function()
    end;
    switch = function()
    end;
    layout = function(self, canvas)
        return canvas:full()
    end;
    draw = function(self, canvas, pos)
    end;
    dispose = function()
    end;
}

local ImagePlayer = Player.extend{
    merge_info = function(self)
        return {
            filename = self.ctx.filename,
        }
    end;
    merge_forward = function(self)
        self.res_reused = true
        return self.res
    end;
    init = function(self, old_res)
        self.res = old_res or resource.load_image{
            file = self.ctx.file:copy(),
            fastload = true,
        }
        self.need_dispose = not old_res
    end;
    draw = function(self, canvas, pos)
        canvas:draw_image(self.res, pos, self.ctx.reveal)
    end;
    dispose = function(self)
        if not self.res_reused then
            self.res:dispose()
        end
    end;
}

local VideoPlayer = Player.extend{
    -- video players should not wrap around:
    -- if (for some rare reasons) only a single video
    -- is assigned once or multiple times to the playlist,
    -- do not continue playback when wrapping. Otherwise
    -- the same video will just run forever and it will
    -- eventually run out of sync when using multiple
    -- displays.
    allow_wrap = false;

    merge_info = function(self)
        return {
            filename = self.ctx.filename,
        }
    end;
    merge_forward = function(self)
        self.res_reused = true
        return self.res
    end;
    init = function(self, old_res)
        self.res = old_res or resource.load_video{
            file = self.ctx.file:copy(),
            raw = true,
            audio = audio,
            paused = true,
            looped = true,
        }
    end;
    switch = function(self)
        self.res:start()
    end;
    draw = function(self, canvas, pos)
        canvas:draw_video(self.res, pos, self.ctx.reveal)
    end;
    dispose = function(self)
        if not self.res_reused then
            self.res:layer(-10)
            self.res:dispose()
        end
    end;
}

local FallbackPlayer = Player.extend{
    merge_info = function(self)
        return {}
    end;
    merge_forward = function(self)
    end;
    draw = function(self, canvas, pos)
        local res = Display.is_portrait() and FallbackV or FallbackH
        canvas:draw_image(res, pos, self.ctx.reveal)
    end;
}

local PluginPlayer = Player.extend{
    merge_info = function(self)
        local module = PluginLoader.modules[self.ctx.filename]
        if module.merge_info then
            return module.merge_info(self.ctx)
        end
    end;
    merge_forward = function(self)
        if self.instance.merge_forward then
            return self.instance.merge_forward()
        end
    end;
    init = function(self, ...)
        local module = PluginLoader.modules[self.ctx.filename]
        self.instance = module.init(self.ctx, ...)
    end;
    switch = function(self)
        if self.instance.switch then
            self.instance.switch()
        end
    end;
    layout = function(self, canvas)
        if self.instance.layout then
            return self.instance.layout(canvas)
        else
            return canvas:full()
        end
    end;
    draw = function(self, canvas, pos)
        if self.instance.draw then
            self.instance.draw(canvas, pos)
        end
    end;
    dispose = function(self)
        if self.instance.dispose then
            self.instance.dispose()
        end
    end;
}

-- Config loading ------------------------------------------------------------

local function create_player(ctx)
    if ctx.asset_type == "fallback" then
        return FallbackPlayer(ctx)
    elseif ctx.asset_type == "image" then
        return ImagePlayer(ctx)
    elseif ctx.asset_type == "video" then
        return VideoPlayer(ctx)
    elseif ctx.asset_type == "child" then
        return PluginPlayer(ctx)
    end
end

local function get_next_base_player_info(config_hash, item_idx, cnt)
    local config = config_by_hash[config_hash]
    if not config then
        return nil, nil
    end
    local playlist = config.playlist

    local item = playlist[item_idx]
    local alternatives = item.alternatives
    local alt_group = alternatives[alternative_idx]
    local player_info = alt_group[cnt % #alt_group + 1]
    if not player_info then
        player_info = alternatives.default[1]
    end
    return item.slot_type, player_info
end

local function get_next_active_overlays(
    config_hash, potential_overlay_groups, base_player_info
)
    local config = config_by_hash[config_hash]
    if not config then
        print('config not found')
        -- Don't use overlays when not having requested config
        return {}
    end

    local active_overlays = {}
    for _, overlay_group in ipairs(config.overlay_groups) do
        if potential_overlay_groups[overlay_group.group_id] then
            local active = true
            for _, condition in ipairs(overlay_group.conditions or {}) do
                -- Continue the evualuation on which overlays are
                -- active. Unlike within python this decision now
                -- depends on the individual base player's properties.
                local condition_type = condition.condition_type 
                if condition_type == "content_type" then
                    active = active and condition.content_type == base_player_info.asset_type
                elseif condition_type == "not_content_type" then
                    active = active and condition.content_type ~= base_player_info.asset_type
                elseif condition_type == "tags_any" then
                    local condition_tags = tags_from_string(condition.tags)
                    active = active and helpers.set_has_overlap(
                        base_player_info.tags, condition_tags
                    )
                elseif condition_type == "tags_none" then
                    local condition_tags = tags_from_string(condition.tags)
                    active = active and not helpers.set_has_overlap(
                        base_player_info.tags, condition_tags
                    )
                end
            end
            if active then
                print('active overlay group', overlay_group.group_id)
                for _, overlay in ipairs(overlay_group.overlays) do
                    table.insert(active_overlays, overlay)
                end
            end
        end
    end
    return active_overlays
end

-- Every time another item is triggered we need to see
-- if the playlist wrapped around. Use the fact that
-- this happens once the item_idx is decreasing (instead
-- of increasing) as a trigger.
local previous_item_idx = 0

-- unique key for the base player
local base_layer_id = newproxy()

local function preload(opt)
    local slot_type, base_player_info = get_next_base_player_info(
        opt.config_hash, opt.item_idx, opt.cnt
    )

    local fallback = not slot_type

    if fallback then
        print "playing fallback"
        slot_type = "fullscreen"
        base_player_info = {
            asset_type = "fallback",
            asset_id = "fallback",
            filename = "fallback",
            tags = {"fallback"},
            file = nil,
            child_config = {},
        }
    end

    local wrapped = false
    if opt.item_idx then
        wrapped = opt.item_idx <= previous_item_idx
        previous_item_idx = opt.item_idx
    end
    if wrapped then
        print('playlist wrapped around')
    end

    local playback_ctx = {
        wrapped = wrapped,
        cnt = opt.cnt,
        rnd = opt.rnd,
        duration = opt.duration or 5,
        slot_type = slot_type,
        fallback = fallback,
    }

    PlayerStack.update_begin(playback_ctx)

    PlayerStack.update_add_layer(base_layer_id, create_player(
        helpers.dict_shallow_merge(
            base_player_info, playback_ctx, {
                is_primary = true,
            }
        )
    ))

    print('loading overlays')
    for overlay_idx, overlay in ipairs(get_next_active_overlays(
        opt.config_hash,
        helpers.list_to_set(opt.ovr or {}),
        base_player_info
    )) do
        print("active overlay", overlay.overlay_id)
        PlayerStack.update_add_layer(overlay.overlay_id, create_player(
            helpers.dict_shallow_merge(
                overlay.player_info, playback_ctx, {
                    is_primary = false,
                    overlay_idx = overlay_idx, 
                }
            )
        ))
    end

    PlayerStack.update_commit()
end

-- Rendering ----------------------------------------------------

local Canvas = helpers.create_class{
    construct = function(self, ctx)
        self.ctx = ctx
        self.area = helpers.Quad(0, 0, Display.size())
        self.layer = -8
    end;

    next_layer = function(self)
        self.layer = self.layer + 1
        return self.layer
    end;

    size = function(self)
        return self.area:size()
    end;

    cut = function(self, side, pixel)
        local layer_quad
        layer_quad, self.area = self.area:cut(side, pixel)
        return layer_quad
    end;

    full = function(self)
        return self.area
    end;

    draw_image = function(self, res, pos, alpha, max_stretch_overwrite)
        local s, w, h = res:state()
        if s == "loaded" then
            local x1, y1, x2, y2 = pos:coords()
            local ox1, oy1, ox2, oy2 = helpers.scale_into(
                x2-x1, y2-y1, w, h,
                max_stretch_overwrite or max_stretch
            )
            Display.draw_image(
                res, x1+ox1, y1+oy1, x1+ox2, y1+oy2, alpha or 1
            )
        end
        return res
    end;

    draw_video = function(self, res, pos, alpha, max_stretch_overwrite)
        local s, w, h = res:state()
        if s == "loaded" or s == "paused" then
            local x1, y1, x2, y2 = pos:coords()
            local ox1, oy1, ox2, oy2 = helpers.scale_into(
                x2-x1, y2-y1, w, h,
                max_stretch_overwrite or max_stretch
            )
            Display.draw_video(
                res, x1+ox1, y1+oy1, x1+ox2, y1+oy2
            ):alpha(alpha or 1):layer(self:next_layer())
        end
        return res
    end;
}

local function force_fallback()
    preload({})
    PlayerStack.switch()
end

-- Service Control ----------------------------------------------------

py.register("update_time", SharedTime.update)
py.register("preload", preload)
py.register("switch", PlayerStack.switch)

-- Force initial switch to fallback content
force_fallback()

function node.render()
    gl.clear(0,0,0,0)
    SharedTime.tick()

    local ctx = PlayerStack.get_ctx()

    -- Force fallback on timeout for current playback stack
    if ctx.ends and sys.now() > ctx.ends + 3 then
        force_fallback()
    end

    if ctx.slot_type == "fullscreen" then
        Display.frame_init(helpers.Quad(0, 0, 100, 100))
    elseif ctx.slot_type == "wall" then
        Display.frame_init(wall_pos)
    end

    PlayerStack.draw(Canvas())

    if sys.now() < show_debug_end then
        debug_overlay(ctx)
    end
end
