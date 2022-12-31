class_name Player

var id

var opponent: Player
var match_id
var username
var character
var discord_id
var rating
var division
var last_heartbeat
var in_tournament

func _init(player_id):
	self.id = player_id
