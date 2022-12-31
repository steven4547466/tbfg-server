extends Node

# The port we will listen to
const characters = '0123456789ABCDEF'

const MAX_PEERS = 2000

const NO_PEERS_RESTART_TIME = 0.25 * 60 * 60

# Our WebSocketServer instance
var _server = WebSocketServer.new()
var restart_timer = Timer.new()
var check_peers_timer = Timer.new()
var send_stats_timer

# Signals
signal discord_id_received(data)
signal tournament_status_received(data)
signal rating_received(data)

var secrets_to_ids = {}
var temp = {}
var callbacks = {}
var http_requests = {}
var matches = {}
var players = {}

var stats_request

var config = {}

func _ready():
	# Connect base signals to get notified of new client connections,
	# disconnections, and disconnect requests.
#	_server.connect("client_connected", self, "_connected")
	# _server.connect("client_disconnected", self, "_disconnected")
#	_server.connect("client_close_request", self, "_close_request")

	var cfg = File.new()
	cfg.open("./config.json", File.READ)
	config = JSON.parse(cfg.get_as_text()).result
	# print(config)
	cfg.close()
	
	_server.connect("peer_connected", self, "_on_peer_connected")
	_server.connect("peer_disconnected", self, "_on_peer_disconnected")
	
	add_child(restart_timer)
	add_child(check_peers_timer)
	restart_timer.connect("timeout", self, "_on_restart_timer_timeout")
	check_peers_timer.connect("timeout", self, "_on_check_peers_timer_timeout")

	if config.enableStatSending:
		stats_request = HTTPRequest.new()
		send_stats_timer = Timer.new()
		add_child(send_stats_timer)
		add_child(stats_request)
		send_stats_timer.connect("timeout", self, "_on_send_stats_timer_timeout")
		send_stats_timer.start(120)

	randomize()

	var err = _server.listen(config.port, PoolStringArray(["binary"]), true)
	if err != OK:
		print("Unable to start server")
		set_process(false)
	else:
		print("Server started on port %d" % [config.port])
	get_tree().set_network_peer(_server)
	restart_timer.start(NO_PEERS_RESTART_TIME)
	check_peers_timer.start(5)

func _on_restart_timer_timeout():
	var num_peers = get_tree().multiplayer.get_network_connected_peers().size()
	print("Connected peers: " + str(num_peers))
#	if num_peers == 0:
#		print("No users connected. restarting...")
#		get_tree().quit()

func _on_send_stats_timer_timeout():
	send_stats()

func _on_check_peers_timer_timeout():
	for id in players:
		if players[id].last_heartbeat < OS.get_unix_time() - 20:
			print("Client %d timed out" % [id])
			var player = players[id]
			if matches.has(player.match_id):
				var other_player = null
				var match_ = matches[player.match_id]
				if match_.host == player:
					if not match_.started:
						match_.selecting = false
					match_.host = null
					other_player = match_.client

				if match_.client == player:
					if not match_.started:
						match_.selecting = false
					match_.client = null
					other_player = match_.host
				
				if other_player != null and match_.started:
					post_game(other_player, player)
					rpc_id(other_player.id, "receive_force_match_end", "opponent_disconnected")

				matches.erase(match_.id)

			if player.spectating != null:
				if matches.has(player.spectating):
					var match_ = matches[player.spectating]
					match_.spectators.erase(player)
					player.spectating = null

			_server.disconnect_peer(id)
			players.erase(id)
		

func _on_peer_connected(id):
	print("Client %d connected" % [id])
	rpc_id(id, "receive_request_validation")
	
#	rpc_id(id, "test_relay")


func _on_peer_disconnected(id):
	print("Client %d disconnected" % [id])
	if players.has(id):
		var player = players[id]
		if matches.has(player.match_id):
			var other_player = null
			var match_ = matches[player.match_id]
			if match_.host == player:
				if not match_.started:
					match_.selecting = false
				match_.host = null
				other_player = match_.client

			if match_.client == player:
				if not match_.started:
					match_.selecting = false
				match_.client = null
				other_player = match_.host

			if other_player != null and match_.started:
				post_game(other_player, player)
				rpc_id(other_player.id, "receive_force_match_end", "opponent_disconnected")

			if match_.host == null and match_.client == null:
				matches.erase(match_.id)

		if player.spectating != null:
			if matches.has(player.spectating):
				var match_ = matches[player.spectating]
				match_.spectators.erase(player)
				player.spectating = null
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
		"invalid_discord_secret": "Invalid discord secret.",
		"not_in_tournament": "You are not in a tournament.",
		"in_tournament": "You are in a tournament.",
		"not_authorized": "You are not authorized to be on this server."
	}
	if error_type in errors:
		rpc_id(id, "server_error", errors[error_type])
	else:
		rpc_id(id, "server_error", "Unknown server error.")

remote func validate_secret(discord_secret):
	# print("Validating secret: " + discord_secret)
	var id = get_tree().get_rpc_sender_id()
	call_deferred("get_discord_id_from_secret", discord_secret, id)

func create_match_callback(in_tournament, id, player_name, options):
	if len(player_name) > 64:
		error(id, "username_too_long")
		return

	if not players.has(id):
		error(id, "not_authorized")
		return

	if config.isTournamentServer and not in_tournament:
		error(id, "not_in_tournament")
		return
	elif not config.isTournamentServer and in_tournament:
		error(id, "in_tournament")
		return

	if not options:
		options = {}
	var match_id = generate_match_id()
	players[id].match_id = match_id
	players[id].username = player_name
	matches[match_id] = Match.new(match_id, players[id])
	matches[match_id].public = options["public"]
	matches[match_id].min_rating = options["min_rating"]
	matches[match_id].max_rating = options["max_rating"]
	# print("created match %s" % [match_id])
	rpc_id(id, "receive_match_id", match_id)

remote func create_match(player_name, options):
	var id = get_tree().get_rpc_sender_id()
	if len(player_name) > 64:
		error(id, "username_too_long")
		return

	if players.has(id):
		if config.isTournamentServer:
			var error = not check_tournament_status(id, players[id].discord_id, "create_match_callback", [id, player_name, options])
			if error:
				error(id, "not_in_tournament")
				return
		else:
			var error = not check_tournament_status(id, players[id].discord_id, "create_match_callback", [id, player_name, options])
			if error:
				error(id, "in_tournament")
				return
	else:
		error(id, "not_authorized")

remote func relay(function, arg):
	var id = get_tree().get_rpc_sender_id()
	if players.has(id):
		var host = players[id]
		var match_ = matches[host.match_id]
		var args
		if arg == null:
			args = [function]
		else:
			args = [function] + (arg if arg is Array else [arg])
		
		if function == "sync_character_selection":
			host.character = PoolStringArray(args[2].name.to_lower().split(" ")).join("_")

		if function == "send_match_data":
			match_.started = true
			match_.start_time = OS.get_unix_time()*1000

		if host.opponent:
			# print("relaying: " + function + " from " + str(id) + " - " + str(arg))
			callv("rpc_id", [host.opponent.id] + args)
			if function != "send_resim_request":
				for spectator in match_.spectators:
					callv("rpc_id", [spectator.id] + args)

func player_join_game_callback(in_tournament, id, player_name, room_code):
	if len(player_name) > 64:
		error(id, "username_too_long")
		return

	if not players.has(id):
		error(id, "not_authorized")
		return

	if config.isTournamentServer and not in_tournament:
		error(id, "not_in_tournament")
		return
	elif not config.isTournamentServer and in_tournament:
		error(id, "in_tournament")
		return

	room_code = room_code.to_upper()

	if players.has(id):
		if matches.has(room_code):
			var player = players[id]
			var match_ = matches[room_code]
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

remote func player_join_game(player_name, room_code):
	var id = get_tree().get_rpc_sender_id()
	if len(player_name) > 64:
		error(id, "username_too_long")
		return
	room_code = room_code.to_upper()

	if players.has(id):
		if matches.has(room_code):
			var match_ = matches[room_code]
			# if match_.started:
			# 	rpc_id(id, "room_join_deny", "Match started.")
			# 	return
			var player = players[id]
			if match_.client != null:
				# rpc_id(id, "room_join_deny", "Room full.")
				match_.spectators.append(player)
				player.spectating = room_code
				rpc_id(id, "room_spectate_confirm")
				if match_.started:
					rpc_id(match_.host.id, "match_data_requested_from_host", id)
				else:
					rpc_id(match_.host.id, "spectator_connected_relay", player_name)
					rpc_id(match_.client.id, "spectator_connected_relay", player_name)
				return

			if match_.host.discord_id == player.discord_id:
				rpc_id(id, "room_join_deny", "You cannot play against yourself.")
				return

			if config.isTournamentServer:
				var error = not check_tournament_status(id, players[id].discord_id, "player_join_game_callback", [id, player_name, room_code])
				if error:
					error(id, "not_in_tournament")
					return
			else:
				var error = not check_tournament_status(id, players[id].discord_id, "player_join_game_callback", [id, player_name, room_code])
				if error:
					error(id, "in_tournament")
					return
		else:
			rpc_id(id, "room_join_deny", "Room with code %s does not exist." % [room_code])
			return
	else: 
		error(id, "not_authorized")

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
	var player = players[id]
	var list = []
	for match_ in matches.values():
		if not ((match_.started or match_.selecting) and match_.open_to_any_spectating) and (match_.min_rating != -1 and player.rating < match_.min_rating):
			continue
		if not ((match_.started or match_.selecting) and match_.open_to_any_spectating) and (match_.max_rating != -1 and player.rating > match_.max_rating):
			continue
		if match_.public or ((match_.started or match_.selecting) and match_.open_to_any_spectating):
			list.append(match_.to_lobby_dict())
		pass
	rpc_id(id, "receive_match_list", list)

remote func fetch_player_count():
#	print("fetching match list")
	var id = get_tree().get_rpc_sender_id()
	var player_count = get_tree().multiplayer.get_network_connected_peers().size() - 1
	rpc_id(id, "receive_player_count", player_count)

remote func set_winner(me):
	var id = get_tree().get_rpc_sender_id()
	# print("updating health %d from %d" % [new_health, id])
	if players.has(id):
		if matches.has(players[id].match_id):
			var winner
			var loser
			if not me:
				winner = players[id].opponent
				loser = players[id]
			else:
				winner = players[id]
				loser = players[id].opponent
			post_game(winner, loser)

remote func heartbeat():
	var id = get_tree().get_rpc_sender_id()
	if players.has(id):
		# print("heartbeat received from %d" % [id])
		players[id].last_heartbeat = OS.get_unix_time()

remote func request_rating():
	# print("requesting rating")
	var id = get_tree().get_rpc_sender_id()
	if players.has(id):
		var player = players[id]
		# print(player.username + " requested rating")
		if player.discord_id != null:
			call_deferred("get_rating", player.discord_id)
		else:
			rpc_id(id, "receive_rating", null)

remote func stop_spectating():
	var id = get_tree().get_rpc_sender_id()
	if players.has(id):
		var player = players[id]
		if player.spectating != null:
			if matches.has(player.spectating):
				var match_ = matches[player.spectating]
				match_.spectators.erase(player)
				rpc_id(match_.host.id, "spectator_disconnected_relay", player.id)
				rpc_id(match_.client.id, "spectator_disconnected_relay", player.id)
				for spectator in match_.spectators:
					rpc_id(spectator.id, "spectator_disconnected_relay", player.id)
				player.spectating = null

remote func request_match_data_from_host():
	var id = get_tree().get_rpc_sender_id()
	if players.has(id):
		var player = players[id]
		if player.spectating != null:
			if matches.has(player.spectating):
				var match_ = matches[player.spectating]
				rpc_id(match_.host.id, "match_data_requested_from_host", id)

remote func receive_match_data_from_host(id, match_data):
	rpc_id(id, "receive_match_data_from_host", match_data)

func secret_received(result, response_code, headers, body):
	var json = body.get_string_from_utf8()
	if json[0] != "{":
		# emit_signal("discord_id_received", null)
		return
	var response = parse_json(json)
	remove_child(http_requests[response.secret])
	http_requests.erase(response.secret)

	var id = secrets_to_ids[response.secret]
	if response.id == null:
		print("Client %d failed to validate" % [id])
		error(id, "invalid_discord_secret")
		_server.disconnect_peer(id, 1008, "Invalid discord secret.")
		secrets_to_ids.erase(response.secret)
		return
	print("Client %d validated" % [id])
	# print(str(response))
	players[id] = Player.new(id)
	players[id].discord_id = response.id
	players[id].rating = response.rating
	players[id].division = response.division
	players[id].last_heartbeat = OS.get_unix_time()
	rpc_id(id, "receive_validation", response.name, response.rating)
	secrets_to_ids.erase(response.secret)
	# print(response.id)
	# emit_signal("discord_id_received", response)

func get_discord_id_from_secret(secret, id):
	# print("Got secret %s" % [secret])
	secrets_to_ids[secret] = id
	if secret == null or secret.strip_edges() == "":
		emit_signal("discord_id_received", {secret: secret, "error": true})
		return
	var http_request = HTTPRequest.new()
	http_requests[secret] = http_request
	add_child(http_request)
	http_request.connect("request_completed", self, "secret_received")
	var error = http_request.request("http://localhost:9666/idfromsecret/" + secret, ["Authorization: %s" % config.authToken])
	if error != OK:
		push_error("An error occurred in the HTTP request.")
		remove_child(http_requests[secret])
		# emit_signal("discord_id_received", {secret: secret, "error": true})
		http_requests.erase(secret)
		secrets_to_ids.erase(secret)

func received_tournament_status(result, response_code, headers, body):
	var json = body.get_string_from_utf8()
	if json[0] != "{":
		# emit_signal("tournament_status_received", null)
		return
	var response = parse_json(json)
	remove_child(http_requests[response.id])
	http_requests.erase(response.id)
	callbacks[response.id]["args"].push_front(response.status)
	callv(callbacks[response.id]["callback"], callbacks[response.id]["args"])
	callbacks.erase(response.id)
	# print(response.id)
	# emit_signal("tournament_status_received", response)

func check_tournament_status(id, discord_id, callback, args):
	if discord_id == null or discord_id.strip_edges() == "":
		return false
	callbacks[discord_id] = {"callback": callback, "args": args}
	var http_request = HTTPRequest.new()
	http_requests[discord_id] = http_request
	add_child(http_request)
	http_request.connect("request_completed", self, "received_tournament_status")
	var error = http_request.request("http://localhost:9666/checktournamentstatus/" + discord_id, ["Authorization: %s" % config.authToken])
	if error != OK:
		push_error("An error occurred in the HTTP request.")
		remove_child(http_requests[discord_id])
		# emit_signal("tournament_status_received", {id: discord_id, "error": true})
		http_requests.erase(discord_id)
		callbacks.erase(discord_id)
		return false
	return true

func post_complete(result, response_code, headers, body):
	var json = body.get_string_from_utf8()
	if json[0] != "{":
		return
	var response = parse_json(json)
	remove_child(http_requests[response.id])
	http_requests.erase(response.id)

func post_game(winner, loser):
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_requests[winner.match_id] = http_request
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
			"tournament": config.isTournamentServer
		}
	})

	http_request.connect("request_completed", self, "post_complete")
	http_request.request("http://localhost:9666/addmatch", ["Content-Type: application/json","Authorization: %s" % config.authToken], false, HTTPClient.METHOD_POST, body)

func send_stats():
	var body = JSON.print({
		"players": get_tree().multiplayer.get_network_connected_peers().size(),
		"matches": matches.size()
	})
	stats_request.request("http://localhost:9666/serverstats", ["Content-Type: application/json","Authorization: %s" % config.authToken], false, HTTPClient.METHOD_POST, body)

func received_rating(result, response_code, headers, body):
	var json = body.get_string_from_utf8()
	if json[0] != "{":
		emit_signal("rating_received", null)
		return
	var response = parse_json(json)
	remove_child(http_requests[response.id])
	http_requests.erase(response.id)
	# print(response.id)
	var player = temp[response.id]
	player.rating = response.rating
	player.division = response.division
	rpc_id(temp[response.id], "receive_rating", response.rating)
	temp.erase(response.id)
	# emit_signal("rating_received", response)

func get_rating(peer_id, id):
	var http_request = HTTPRequest.new()
	add_child(http_request)
	temp[id] = peer_id
	http_requests[id] = http_request
	http_request.connect("request_completed", self, "received_rating")
	var error = http_request.request("http://localhost:9666/getrating/" + str(id), ["Authorization: %s" % config.authToken])
	if error != OK:
		push_error("An error occurred in the HTTP request.")
		# emit_signal("rating_received", {id: id, "error": true})
		remove_child(http_request)
		http_requests.erase(id)
		rpc_id(id, "receive_rating", null)