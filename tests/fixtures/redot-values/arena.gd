extends Node
# Every frame: _process -> Player.act -> Player.swing -> Dummy.take_hit, which
# sleeps in native code. The members below are one value of every Variant
# type, for a debugger to show. The process ends by itself so that a lost run
# cannot linger.

const LIFETIME_MSEC := 600000
var frames: int = 0
var v_nil = null
var v_bool: bool = true
var v_int: int = -42
var v_float: float = 2.5
var v_whole: float = 3.0
var v_string: String = "héllo wörld"
var v_name: StringName = &"beta_name"
var v_path: NodePath = ^"/root/Arena/Player:position:x"
var v_relative: NodePath = ^"Player/Hand"
var v_vec2 := Vector2(3.25, -4.5)
var v_vec2i := Vector2i(7, -9)
var v_rect := Rect2(1, 2, 30, 40)
var v_recti := Rect2i(1, 2, 3, 4)
var v_vec3 := Vector3(1, 2, 0.5)
var v_vec3i := Vector3i(1, -2, 3)
var v_xform2d := Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(5, 6))
var v_vec4 := Vector4(1, 2, 3, 4)
var v_vec4i := Vector4i(1, 2, 3, -4)
var v_plane := Plane(0, 1, 0, 2.5)
var v_quat := Quaternion(0, 0, 0, 1)
var v_aabb := AABB(Vector3(1, 2, 3), Vector3(4, 5, 6))
var v_basis := Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9))
var v_xform3d := Transform3D(Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9)), Vector3(10, 11, 12))
var v_proj := Projection(Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0), Vector4(5, 6, 7, 1))
var v_color := Color(1, 0.5, 0.25, 1)
var v_rid: RID = rid_from_int64(77)
var v_node: Node = null
var v_ref: RefCounted = RefCounted.new()
var v_null: Object = null
var v_freed = null
var v_callable: Callable = Callable(self, "noted")
var v_lambda: Callable = func(): return 1
var v_signal: Signal = tree_exiting
var v_dict := {"k_int": 4, "k_str": "alpha", 7: 2.5, &"k_name": Vector2i(1, 2)}
var v_array := [4, 1.5, "alpha", Vector2(3.25, -4.5), [1, [2]], {"a": 1}, null]
var v_bytes := PackedByteArray([1, 2, 255])
var v_i32 := PackedInt32Array([10, 20, -30])
var v_i64 := PackedInt64Array([1099511627776, -5])
var v_f32 := PackedFloat32Array([1.5, -0.25])
var v_f64 := PackedFloat64Array([2.718281828, 0.001])
var v_strings := PackedStringArray(["a", "bc"])
var v_vec2s := PackedVector2Array([Vector2(1, 2), Vector2(3, 4)])
var v_vec3s := PackedVector3Array([Vector3(1, 2, 3)])
var v_colors := PackedColorArray([Color(1, 0, 0, 1)])
var v_vec4s := PackedVector4Array([Vector4(1, 2, 3, 4)])
var v_big: Array = range(100)
var v_long: String = "x".repeat(300)
var v_empty: Array = []
var v_none: Dictionary = {}

func _ready() -> void:
	v_node = $Player
	var gone := Node.new()
	var gone_id := gone.get_instance_id()
	v_freed = gone
	gone.free()
	print("PID ", OS.get_process_id())
	# What the engine itself prints for the values whose text a debugger
	# should show unchanged, and the ids only this run knows.
	var text := {}
	for name in ["v_int", "v_float", "v_whole", "v_vec2", "v_vec2i", "v_rect", "v_recti", "v_vec3", "v_vec3i", "v_xform2d", "v_vec4", "v_vec4i", "v_plane", "v_quat", "v_aabb", "v_basis", "v_xform3d", "v_color"]:
		text[name] = str(get(name))
	print("ORACLE text ", JSON.stringify(text))
	print("ORACLE ids ", JSON.stringify({"arena": get_instance_id(), "player": $Player.get_instance_id(), "hand": $Player/Hand.get_instance_id(), "dummy": $Dummy.get_instance_id(), "ref": v_ref.get_instance_id(), "freed": gone_id}))

func noted() -> void:
	pass

func _process(delta: float) -> void:
	frames += 1
	if Time.get_ticks_msec() > LIFETIME_MSEC:
		get_tree().quit()
		return
	$Player.act(frames, $Dummy)
