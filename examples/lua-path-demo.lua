-- Watch state.player.score while this program replaces the containing table.
local function demo()
    local state = {player = {score = 7}}
    for round = 1, 10 do
        print(round, state.player.score)
        state.player = {score = state.player.score + 1}
        collectgarbage('collect')
    end
end
demo()
