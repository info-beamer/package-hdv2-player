local api = ...

local M = {}

local white = resource.create_colored_texture(1,1,1,1)
local black = resource.create_colored_texture(0,0,0,1)
local font = resource.load_font(api.localized(
    "font.ttf"
))

local shaders = {
    progress = resource.create_shader[[
        uniform sampler2D Texture;
        varying vec2 TexCoord;
        uniform float progress_angle;

        float interp(float x) {
            return 2.0 * x * x * x - 3.0 * x * x + 1.0;
        }

        void main() {
            vec2 pos = TexCoord;
            float angle = atan(pos.x - 0.5, pos.y - 0.5);
            float dist = clamp(distance(pos, vec2(0.5, 0.5)), 0.0, 0.5) * 2.0;
            float alpha = interp(pow(dist, 8.0));
            if (angle > progress_angle) {
                gl_FragColor = vec4(1.0, 1.0, 1.0, alpha);
            } else {
                gl_FragColor = vec4(0.5, 0.5, 0.5, alpha);
            }
        }
    ]]
}

local function instance(ctx)
    local function layout(canvas)
        return canvas:full()
    end

    local function draw(canvas, target)
        local mode = ctx.child_config.mode or 'bar_thin_white'
        local progress = ctx.progress
        local w = target.x2 - target.x1
        local h = target.y2 - target.y1
        local x = target.x1
        local y = target.y1
        if mode == "bar_thin_white" then
            white:draw(x, y+h-10, x+w*progress, y+h, 0.5)
        elseif mode == "bar_thick_white" then
            white:draw(x, y+h-20, x+w*progress, y+h, 0.5)
        elseif mode == "bar_thin_black" then
            black:draw(x, y+h-10, x+w*progress, y+h, 0.5)
        elseif mode == "bar_thick_black" then
            black:draw(x, y+h-20, x+w*progress, y+h, 0.5)
        elseif mode == "circle" then
            shaders.progress:use{
                progress_angle = math.pi - progress * math.pi * 2
            }
            white:draw(x+w-40, y+h-40, x+w-10, y+h-10)
            shaders.progress:deactivate()
        elseif mode == "countdown" then
            local remaining = math.ceil(-ctx.now + ctx.ends)
            local text
            if remaining >= 60 then
                text = string.format("%d:%02d", remaining / 60, remaining % 60)
            else
                text = remaining
            end
            local size = 32
            local tw = font:width(text, size)
            black:draw(x+w-tw-4, y+h-size - 4, x+w, y+h, 0.6)
            font:write(x+w-tw-2, y+h-size - 2, text, size, 1,1,1,0.8)
        end

    end

    return {
        layout = layout;
        draw = draw;
    }
end

function M.init(ctx)
    return instance(ctx)
end

return M
