extends Node

var checksum: int = 0
var inventory = {"sword": {"damage": 12, "tags": ["sharp", "steel"]}, "potions": [3, 5, 8]}

func _process(_delta):
    burn()

func burn():
    var frame_number = Engine.get_process_frames()
    var deadline = Time.get_ticks_usec() + 12000
    while Time.get_ticks_usec() < deadline:
        for index in range(800):
            checksum = (checksum + index) % 100000
    # A real native call under the script, visible in a stopped native sample.
    OS.delay_msec(6)
    if frame_number < 160:
        print("ORACLE frame ", JSON.stringify({"process": frame_number, "physics": Engine.get_physics_frames(), "owner": get_instance_id(), "function": "burn"}))

func _physics_process(_delta):
    checksum = (checksum + 1) % 100000
