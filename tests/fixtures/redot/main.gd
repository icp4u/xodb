extends Node
# Every frame: _process -> plan -> Worker.step -> Worker.leaf, which sleeps in
# native code. The process ends by itself so that a lost run cannot linger.

const LIFETIME_MSEC := 600000
var frames: int = 0

func _ready() -> void:
	print("PID ", OS.get_process_id())

func _process(_delta: float) -> void:
	frames += 1
	if Time.get_ticks_msec() > LIFETIME_MSEC:
		get_tree().quit()
		return
	plan(frames)

func plan(n: int) -> int:
	var doubled: int = n * 2
	return $Worker.step(doubled, "plan-%d" % (n % 5))
