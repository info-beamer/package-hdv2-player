local api = ...

local M = {}

local function instance(ctx)
    local function layout(canvas)
        local w, h = canvas:size()
        canvas:cut('left',   w / 100 * (ctx.child_config.x1 or 0))
        canvas:cut('top',    h / 100 * (ctx.child_config.y1 or 0))
        canvas:cut('right',  w / 100 * (ctx.child_config.x2 or 0))
        canvas:cut('bottom', h / 100 * (ctx.child_config.y2 or 0))
    end
    return {
        layout = layout;
    }
end

function M.init(ctx)
    return instance(ctx)
end

return M
