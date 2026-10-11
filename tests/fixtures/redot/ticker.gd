extends Node
# A second route into script code: a Timer signal handler.

var ticks: int = 0

func _ready() -> void:
	$Timer.timeout.connect(_on_timeout)

func _on_timeout() -> void:
	ticks += 1
	count(ticks)

func count(n: int) -> void:
	if n % 20 == 0:
		print("TICK ", n)
