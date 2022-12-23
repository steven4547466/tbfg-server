class_name Match

var host: Player
var client: Player
var id
var start_time
var selecting = false
var started = false
var public = true

func _init(match_id, host_player):
	self.id = match_id
	self.host = host_player

func to_lobby_dict():
	return {
		"host": host.username,
		"code": id,
		"rating": host.rating,
	}
