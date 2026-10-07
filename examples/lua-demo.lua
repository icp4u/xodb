-- Stop inside print, before it formats the value or runs a metamethod.
local captured = 73
local function closure() return captured end
local values = {42, -7, 3.5, 'hello', {1, 2, answer=42}, closure}
local function inspect(value)
    print(value) -- xodb's luaB_print breakpoint: watch L for the top value.
end
local function tick()
    for _, value in ipairs(values) do inspect(value) end
end
for _ = 1, 20 do tick() end
