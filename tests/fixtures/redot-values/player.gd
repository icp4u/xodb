extends Node2D
# A player with state worth looking at: a nested inventory, vectors, a typed
# member, and references to its child node and to its target.

var title: String = "Aria"
var hp: int = 90
var speed: float = 2.5
var alive: bool = true
var velocity: Vector2 = Vector2(3.25, -4.5)
var tint: Color = Color(1, 0.5, 0.25, 1)
var inventory: Dictionary = {
	"sword": {"damage": 12, "tags": ["sharp", "steel"], "reach": 1.5},
	"potions": [3, 5, 8],
	"gold": 250,
	7: "lucky",
}
var items: Array = ["sword", "shield", "bow"]
var waypoints: PackedVector2Array = PackedVector2Array([Vector2(0, 0), Vector2(10, 2.5)])
@onready var hand: Node2D = $Hand
var target: Node2D = null
var swings: int = 0

func _ready() -> void:
	position = Vector2(12.5, -7.25)

func act(frame: int, dummy: Node2D) -> void:
	target = dummy
	var weapon: Dictionary = inventory["sword"]
	var reach: float = weapon["reach"]
	swings += swing(weapon, reach * 2.0)

func swing(weapon: Dictionary, power: float) -> int:
	var damage: int = weapon["damage"]
	var tags: Array = weapon["tags"]
	var aim: Vector2 = velocity * 2.0
	return target.take_hit(self, damage, aim)
