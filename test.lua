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


local FallbackImage = create_class{
    construct = function(self)
        self.asset = 'foo'
    end;
    hehe = 1;
    fnord = 1;
    doo = function(self)
        print(self.asset)
        print(self.fnord)
    end
}

local Rotz = FallbackImage.extend{
    hehe = 2;
}

local i = FallbackImage() 
print(i.fnord)

i:doo()
print(i.hehe)

