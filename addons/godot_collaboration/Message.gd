extends Resource

class_name Message

@export var type : String
@export var data : Dictionary = {}

func _init(t : String = "", d : Dictionary = {}) -> void:
	type = t
	data = d

func from_json(json_string : String) -> void:
	var response = JSON.parse_string(json_string)
	
	type = response["type"]
	data = response["data"]

func to_json() -> String:
	return JSON.stringify({
		"type":type,
		"data":data
	})
