extends Node

# The port we will listen to
const PORT = 52450
const characters = '0123456789ABCDEF'

const MAX_PEERS = 2000

const NO_PEERS_RESTART_TIME = 0.25 * 60 * 60

# Our WebSocketServer instance
var _server = WebSocketServer.new()
var restart_timer = Timer.new()
var send_stats_timer = Timer.new()

# Signals
signal discord_id_received(discord_id)

var http_requests = {}
var matches = {}
var players = {}

var stats_request = HTTPRequest.new()

var config = {}

func _ready():
	# Connect base signals to get notified of new client connections,
	# disconnections, and disconnect requests.
#	_server.connect("client_connected", self, "_connected")
#	_server.connect("client_disconnected", self, "_disconnected")
#	_server.connect("client_close_request", self, "_close_request")

	var cfg = File.new()
	cfg.open("./config.json", File.READ)
	config = JSON.parse(cfg.get_as_text()).result
	print(config)
	cfg.close()
	
	_server.connect("peer_connected", self, "_on_peer_connected")
	_server.connect("peer_disconnected", self, "_on_peer_disconnected")
	
	add_child(restart_timer)
	add_child(send_stats_timer)
	add_child(stats_request)
	restart_timer.connect("timeout", self, "_on_restart_timer_timeout")
	send_stats_timer.connect("timeout", self, "_on_send_stats_timer_timeout")
	randomize()

	var err = _server.listen(PORT, PoolStringArray(["binary"]), true)
	if err != OK:
		print("Unable to start server")
		set_process(false)
	else:
		print("Server started on port %d" % [PORT])
	get_tree().set_network_peer(_server)
	restart_timer.start(NO_PEERS_RESTART_TIME)
	send_stats_timer.start(120)

func _on_restart_timer_timeout():
	var num_peers = get_tree().multiplayer.get_network_connected_peers().size()
	print("Connected peers: " + str(num_peers))
#	if num_peers == 0:
#		print("No users connected. restarting...")
#		get_tree().quit()

func _on_send_stats_timer_timeout():
	send_stats()

func _on_peer_connected(id):
	print("Client %d connected" % [id])
	players[id] = Player.new(id)
	
#	rpc_id(id, "test_relay")


func _on_peer_disconnected(id):
#	print("Client %d disconnected" % [id])
	if matches.has(players[id].match_id):
		var match_ = matches[players[id].match_id]
		if match_.host == players[id]:
			match_.host = null
		if match_.client == players[id]:
			match_.client = null
		if match_.host == null and match_.client == null:
#			print("removing match %s" % [match_.id])
			matches.erase(match_.id)
	players.erase(id)

func generate_match_id():
	var id = ""
	for _i in range(4):
		id += characters[randi() % len(characters)]
	if id in matches:
		return generate_match_id()
	return id

func error(id, error_type):
	var errors = {
		"username_too_long": "Username too long. Please try again with a shorter username.",
		"server_full": "Dojo full.",
		"invalid_discord_secret": "Invalid discord secret."
	}
	if error_type in errors:
		rpc_id(id, "server_error", errors[error_type])
	else:
		rpc_id(id, "server_error", "Unknown server error.")

remote func create_match(player_name, public, discord_secret):
	var id = get_tree().get_rpc_sender_id()
	if len(player_name) > 64:
		error(id, "username_too_long")
	
	call_deferred("get_discord_id_from_secret", discord_secret)
	var discord_id = yield(self, "discord_id_received") 
	if discord_id == null:
		error(id, "invalid_discord_secret")
		return

	if players.has(id):
		players[id].discord_id = discord_id
		var match_id = generate_match_id()
		players[id].match_id = match_id
		players[id].username = player_name
		matches[match_id] = Match.new(match_id, players[id])
		matches[match_id].public = public
		# print("created match %s" % [match_id])
		rpc_id(id, "receive_match_id", match_id)

remote func relay(function, arg):
	var id = get_tree().get_rpc_sender_id()
	if players.has(id):
		var host = players[id]
		var args
		if arg == null:
			args = [function]
		else:
			args = [function] + (arg if arg is Array else [arg])
		
		if function == "sync_character_selection":
			host.character = PoolStringArray(args[2].name.to_lower().split(" ")).join("_")

		if function == "send_match_data":
			var match_ = matches[host.match_id]
			match_.started = true
			match_.start_time = OS.get_unix_time()*1000

		if host.opponent:
			# print("relaying: " + function + " from " + str(id) + " - " + str(arg))
			callv("rpc_id", [host.opponent.id] + args)

remote func player_join_game(player_name, room_code, discord_secret):
	var id = get_tree().get_rpc_sender_id()
	if len(player_name) > 64:
		error(id, "username_too_long")
		return
	room_code = room_code.to_upper()
	call_deferred("get_discord_id_from_secret", discord_secret)
	var discord_id = yield(self, "discord_id_received") 
	if discord_id == null:
		rpc_id(id, "room_join_deny", "Invalid discord secret.")
		return

	if matches.has(room_code) and players.has(id):
		var match_ = matches[room_code]
		var player = players[id]
		if match_.client != null:
			rpc_id(id, "room_join_deny", "Room full.")
			return
		player.discord_id = discord_id
		if match_.host.discord_id == player.discord_id:
			rpc_id(id, "room_join_deny", "You cannot play against yourself.")
			return
		match_.client = player
		match_.host.opponent = player
		player.opponent = match_.host
		player.match_id = room_code
		player.username = player_name
		match_.selecting = true
#		print("player %d joined match %s" % [id, room_code])
		rpc_id(id, "room_join_confirm")
		rpc_id(id, "player_connected_relay")
		rpc_id(match_.host.id, "player_connected_relay")
	else:
		rpc_id(id, "room_join_deny", "Room with code %s does not exist." % [room_code])
		return

func check_server_full(id):
#	if get_tree().multiplayer.get_network_connected_peers().size() > MAX_PEERS:
#		error(id, "server_full")
#		yield(get_tree().create_timer(1.0), "timeout")
#		_server.disconnect_peer(id)
#		return true
	return false

remote func fetch_match_list():
#	print("fetching match list")
	var id = get_tree().get_rpc_sender_id()
	if check_server_full(id):
		return
	var list = []
	for match_ in matches.values():
		if !match_.selecting and !match_.started and match_.public:
			list.append(match_.to_lobby_dict())
		pass
	rpc_id(id, "receive_match_list", list)

remote func fetch_player_count():
#	print("fetching match list")
	var id = get_tree().get_rpc_sender_id()
	var player_count = get_tree().multiplayer.get_network_connected_peers().size() - 1
	rpc_id(id, "receive_player_count", player_count)

remote func set_winner():
	var id = get_tree().get_rpc_sender_id()
	# print("updating health %d from %d" % [new_health, id])
	if players.has(id):
		var winner = players[id].opponent
		var loser = players[id]
		post_game(winner, loser)

func secret_received(result, response_code, headers, body):
	var response = parse_json(body.get_string_from_utf8())
	remove_child(http_requests[response.secret])
	http_requests.erase(response.secret)
	# print(response.id)
	emit_signal("discord_id_received", response.id)

func get_discord_id_from_secret(secret):
	# print("Got secret %s" % [secret])
	if secret == null or secret.strip_edges() == "":
		emit_signal("discord_id_received", null)
		return
	var http_request = HTTPRequest.new()
	http_requests[secret] = http_request
	add_child(http_request)
	http_request.connect("request_completed", self, "secret_received")
	var error = http_request.request("http://localhost:9666/idfromsecret/" + secret, ["Authorization: %s" % config.authToken])
	if error != OK:
		push_error("An error occurred in the HTTP request.")
		remove_child(http_requests[secret])
		http_requests.erase(secret)

func post_game(winner, loser):
	var http_request = HTTPRequest.new()
	add_child(http_request)
	var match_ = matches[winner.match_id]
	var body = JSON.print({
		"p1": {
			"id": winner.discord_id,
			"character": winner.character
		},
		"p2": {
			"id": loser.discord_id,
			"character": loser.character
		},
		"overrides": {
			"startedAt": match_.start_time,
		}
	})
	http_request.request("http://localhost:9666/addmatch", ["Content-Type: application/json","Authorization: %s" % config.authToken], false, HTTPClient.METHOD_POST, body)

func send_stats():
	var body = JSON.print({
		"players": get_tree().multiplayer.get_network_connected_peers().size(),
		"matches": matches.size()
	})
	stats_request.request("http://localhost:9666/serverstats", ["Content-Type: application/json","Authorization: %s" % config.authToken], false, HTTPClient.METHOD_POST, body)