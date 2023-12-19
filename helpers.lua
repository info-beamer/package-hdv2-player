local name = ...

local matrix = require "matrix2d"

local function create_class(methods)
    local class
    class = setmetatable({
        extend = function(child_methods)
            child_methods.super = function(self, ...)
                methods.construct(self, ...)
            end
            return create_class(setmetatable(child_methods, {
                __index = methods
            }))
        end;
    }, {
        __call = function(_, ...)
            local instance = setmetatable({}, {
                __index = methods
            })
            instance:construct(...)
            return instance
        end
    })
    return class
end

local Quad; Quad = create_class{
    construct = function(self, x1, y1, x2, y2)
        self.x1, self.y1 = x1, y1
        self.x2, self.y2 = x2, y2
    end;

    cut = function(self, side, pixel)
        if side == "left" then
            return Quad(self.x1, self.y1, self.x1 + pixel, self.y2),
                   Quad(self.x1 + pixel, self.y1, self.x2, self.y2)
        elseif side == "top" then
            return Quad(self.x1, self.y1, self.x2, self.y1 + pixel),
                   Quad(self.x1, self.y1 + pixel, self.x2, self.y2)
        elseif side == "right" then
            return Quad(self.x2 - pixel, self.y1, self.x2, self.y2),
                   Quad(self.x1, self.y1, self.x2 - pixel, self.y2)
        elseif side == "bottom" then
            return Quad(self.x1, self.y2 - pixel, self.x2, self.y2),
                   Quad(self.x1, self.y1, self.x2, self.y2 - pixel)
        else
            error("invalid cut side")
        end
    end;

    move = function(self, x, y)
        return Quad(
            self.x1 + x,
            self.y1 + y,
            self.x2 + x,
            self.y2 + y
        )
    end;
    
    
    coords = function(self)
        return self.x1, self.y1, self.x2, self.y2
    end;

    as_table = function(self)
        return {
            x1 = self.x1,
            y1 = self.y1,
            x2 = self.x2,
            y2 = self.y2,
        }
    end;

    size = function(self)
        return self.x2-self.x1, self.y2-self.y1
    end;
}


local function scale_into(target_w, target_h, w, h, max_stretch)
    local scale_x = target_w / w
    local scale_y = target_h / h
    local max_scale = math.min(scale_x, scale_y)
    if scale_x == max_scale then
        scale_y = math.min(scale_y, max_scale * max_stretch)
    else
        scale_x = math.min(scale_x, max_scale * max_stretch)
    end
    local transform = matrix.trans(target_w/2, target_h/2) *
                      matrix.scale(scale_x, scale_y) *
                      matrix.trans(-w/2, -h/2)
    local x1, y1 = transform(0, 0)
    local x2, y2 = transform(w, h)
    return x1, y1, x2, y2
end

local function str_split(s, sep)
    local fields = {}
    local sep = sep or " "
    local pattern = string.format("([^%s]+)", sep)
    string.gsub(s, pattern, function(c) fields[#fields + 1] = c end)
    return fields
end

local function dict_shallow_equal(t1, t2)
    local t1_type = type(t1)
    local t2_type = type(t2)
    if t1_type ~= 'table' then return false end
    if t2_type ~= t1_type then return false end
    if t1 == t2 then return true end

    local seen = {}
    for k, v1 in pairs(t1) do
        local v2 = t2[k]
        if v2 == nil or v1 ~= v2 then
            return false
        end
        seen[k] = true
    end
    for k, _ in pairs(t2) do
        if not seen[k] then return false end
    end
    return true
end

local function dict_shallow_merge(...)
    local out = {}
    for _, table in ipairs({...}) do
        for k, v in pairs(table) do
            out[k] = v
        end
    end
    return out
end

local function list_concat(...)
    local out = {}
    for _, table in ipairs({...}) do
        for _, v in ipairs(table) do
            out[#out+1] = v
        end
    end
    return out
end

local function list_to_set(list)
    local set = {}
    for _, item in ipairs(list) do
        set[item] = true
    end
    return set
end

local function set_has_overlap(a, b)
    for k, _ in pairs(b) do
        if a[k] then
            return true
        end
    end
    return false
end

local function set_union(...)
    local union = {}
    for _, set in ipairs({...}) do
        for k, _ in pairs(set) do
            union[k] = true
        end
    end
    return union
end

local BAR = 'IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII........................................'
local function progress_bar_string(progress)
    progress = math.max(0, math.min(1, progress))
    local bar_progress = math.max(1, 40-math.floor(progress*40))
    return string.format(
        '[%s] %.2f%%', BAR:sub(bar_progress, bar_progress+39), progress*100
    )
end

return {
    Quad = Quad,
    progress_bar_string = progress_bar_string,
    scale_into = scale_into,
    list_to_set = list_to_set,
    list_concat = list_concat,
    dict_shallow_equal = dict_shallow_equal,
    dict_shallow_merge = dict_shallow_merge,
    str_split = str_split,
    set_has_overlap = set_has_overlap,
    set_union = set_union,
    create_class = create_class,
}
