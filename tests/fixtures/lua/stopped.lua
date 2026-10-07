local captured = 73
local function closure() return captured end
local function values()
    inspect(nil, 'nil')
    inspect(false, 'false')
    inspect(true, 'true')
    inspect(42, 'integer')
    inspect(-73, 'negative')
    inspect(3.5, 'number')
    inspect('hi', 'string')
    inspect('a\0b\255', 'bytes')
    inspect(string.rep('x',300), 'long')
    inspect({1,2,x='hi'}, 'table')
    inspect({}, 'empty')
    inspect(closure, 'closure')
    inspect(inspect, 'c_function')
    inspect(coroutine.running(), 'thread')
    inspect(io.tmpfile(), 'userdata')
end
local function nested(n)
    if n > 0 then nested(n-1) else values() end
end
nested(3)
function inner() inspect('C-Lua-C', 'sandwich') end
sandwich()
local function tail(n)
    if n == 0 then inspect('tail', 'tail') else return tail(n-1) end
end
tail(3)
local co=coroutine.create(function()
    inspect('coroutine', 'coroutine')
    coroutine.yield()
    inspect('resumed', 'resumed')
end)
assert(coroutine.resume(co))
inspect(co, 'suspended_coroutine')
assert(coroutine.resume(co))
assert(pcall(function() inspect('pcall', 'pcall') end))
xpcall(function() error('owned fixture error') end, function(e) inspect(e, 'error') end)
inspect(co, 'dead_coroutine')
