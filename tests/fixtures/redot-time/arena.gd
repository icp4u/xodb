extends Node

func _ready():
    print("ORACLE ids ", JSON.stringify({"slow": $Slow.get_instance_id(), "light": $Light.get_instance_id(), "light_twin": $LightTwin.get_instance_id()}))
