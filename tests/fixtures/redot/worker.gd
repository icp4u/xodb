extends Node
# The innermost script frames. `leaf` records the engine's own answer to
# "what is the script stack here" on the line where it then sleeps in native
# code, so a debugger stopped in that sleep can be checked against it.

const PAUSE_MSEC := 20
var announced: bool = false
var total: int = 0

func step(n: int, label: String) -> int:
	var scaled: int = n + label.length()
	total += leaf(scaled)
	return total

func leaf(n: int) -> int:
	var here: Array = get_stack(); OS.delay_msec(PAUSE_MSEC)
	if not announced:
		announced = true
		print("ORACLE stack ", JSON.stringify(here))
		# A planted wrong answer: the same stack with one line off by one.
		var wrong: Array = here.duplicate(true)
		wrong[0]["line"] += 1
		print("ORACLE wrong ", JSON.stringify(wrong))
	return n % 7
