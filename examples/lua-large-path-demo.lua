-- A large module-like table stays readable across rehash and child replacement.
assert(_VERSION == 'Lua 5.4', 'this demo uses Lua 5.4 table-path lookup')
local module = {player = {score = 7}}
for i = 1, 2000 do module['field' .. i] = i end
for score = 7, 16 do
    module.player = {score = score}
    for i = 1, 300 do module['extra' .. score .. '_' .. i] = i end
    print(module.player.score)
end
