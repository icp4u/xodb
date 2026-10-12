extends Node2D
# The innermost script frame. `take_hit` records the engine's own answer to
# "what is the script stack here" on the line where it then sleeps in native
# code, so a debugger stopped in that sleep can be checked against it.

const PAUSE_MSEC := 20
var armor: int = 3
var hits: Array = []
var announced: bool = false

func take_hit(from: Node2D, damage: int, aim: Vector2) -> int:
	var dealt: int = max(damage - armor, 0)
	var note: String = "%s hits for %d" % [from.title, dealt]
	var here: Array = get_stack(); OS.delay_msec(PAUSE_MSEC)
	if not announced:
		announced = true
		hits.append(note)
		print("ORACLE stack ", JSON.stringify(here))
		print("ORACLE locals ", JSON.stringify({"damage": damage, "dealt": dealt, "note": note, "armor": armor, "hp": from.hp, "gold": from.inventory["gold"]}))
		print("ORACLE inventory ", JSON.stringify(from.inventory))
		# A planted wrong answer: the same values with one of them off by one.
		print("ORACLE wrong ", JSON.stringify({"damage": damage, "dealt": dealt + 1, "note": note, "armor": armor, "hp": from.hp, "gold": from.inventory["gold"]}))
	return dealt
