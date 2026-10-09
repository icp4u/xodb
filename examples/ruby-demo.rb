# Stop in rb_ary_store, select tick in the Ruby tab, then E round Return.
def tick(values, round)
  doubled = round * 2
  state = :ready
  summary = {state: state, round: round}
  retained = -> { doubled }
  values[round % values.length] = round
  retained.call
end

values = [0, 0, 0, 0]
round = 0
$stdout.sync = true
puts Process.pid
loop do
  tick(values, round)
  round += 1
end
