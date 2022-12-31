class_name Match

var host: Player
var client: Player
var id
var start_time
var selecting = false
var started = false
var public = true
var spectators = []
var min_rating
var max_rating
var open_to_any_spectating = true

func _init(match_id, host_player):
	self.id = match_id
	self.host = host_player

func to_lobby_dict():
	return {
		"host": host.username,
		"client": client.username if client else null,
		"client_rating": client.rating if client else null,
		"client_division": client.division if client else null,
		"division": host.division,
		"code": id,
		"rating": host.rating,
		"spectate": started or selecting,
	}
