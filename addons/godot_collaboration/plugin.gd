@tool
extends EditorPlugin

var dock


# server
var server := TCPServer.new()
var is_server := false
# connection list
var connections := {}

var client := StreamPeerTCP.new()
var is_client := false
var client_connected := false
var client_id = -1

# Client file receiving stuff
var client_receiving_file := false
var client_file_name := ""
var client_file_size := 0
var client_received_size := 0
var client_file_data := PackedByteArray()
var client_file_path := ""

# client code editor
var client_carets = []

# ui elements
var dock_connection_panel : Control
var dock_host_btn : Button
var dock_connect_btn : Button
var dock_server_port_input : LineEdit
var dock_server_address_input : LineEdit
var dock_username_input : LineEdit
var dock_user_color_input : ColorPicker

var dock_server_panel : Control
var dock_server_stop_btn : Button
var dock_server_force_sync_btn : Button
var dock_server_client_list : ItemList

var dock_client_panel : Control
var dock_client_stop_btn : Button
var dock_client_clients_list : ItemList

# code editor
var script_editor : ScriptEditor
var current_code_edit : CodeEdit
var current_script : Script

func _enter_tree():
	# add the dock to editor
	dock = preload("res://addons/godot_collaboration/dock.tscn").instantiate()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL,dock)
	
	# assign the ui elements variables
	assign_ui_elements()
	
	# connect the signals from the buttons
	dock_host_btn.connect("pressed",start_server)
	dock_connect_btn.connect("pressed",start_client)
	
	dock_server_stop_btn.connect("pressed",stop_server)
	dock_server_force_sync_btn.connect("pressed",sync_all_files_with_everyone)
	
	dock_client_stop_btn.connect("pressed",stop_client)
	
	# script editor
	script_editor = get_editor_interface().get_script_editor()
	script_editor.editor_script_changed.connect(_on_script_changed)

func _on_script_changed(script : Script):
	print(script.resource_path)
	current_script = script
	if current_code_edit:
		current_code_edit.draw.disconnect(_draw_carets)
		current_code_edit.caret_changed.disconnect(_caret_changed)
	
	await get_tree().process_frame  # Wait for the editor to update
	
	var script_editor_base = script_editor.get_current_editor()
	current_code_edit = script_editor_base.get_base_editor()
	
	if current_code_edit:
		current_code_edit.draw.connect(_draw_carets)
		current_code_edit.caret_changed.connect(_caret_changed)
	
	if is_client:
		var msg = Message.new("current_script_path")
		msg.data.script_path = script.resource_path
		
		client_send_message(msg)

func server_broadcast_carets():
	
	var carets = []
	
	if current_code_edit:
		carets.append({
			"color":{
				"r": dock_user_color_input.color.r,
				"g": dock_user_color_input.color.g,
				"b": dock_user_color_input.color.b
			},
			"line":current_code_edit.get_caret_line(),
			"column":current_code_edit.get_caret_column(),
			"path": current_script.resource_path,
			"id":0
		})
	
	for id in connections:
		var data = connections[id]
		
		carets.append({
			"color":{
				"r": data.color.r,
				"g": data.color.g,
				"b": data.color.b
			},
			"line":data.current_script.caret_line,
			"column":data.current_script.caret_column,
			"path":data.current_script.path,
			"id":id
		})
	
	var msg = Message.new("carets")
	msg.data.carets = carets
	
	server_broadcast(msg)
	

func _caret_changed():
	# the caret changed
	# send the current caret line and column to the server
	if is_client:
		var caret_pos = current_code_edit.get_caret_draw_pos()
		# send the caret positions to the server
		var msg = Message.new("caret_position")
		msg.data.line = current_code_edit.get_caret_line()
		msg.data.column = current_code_edit.get_caret_column()
		
		client_send_message(msg)
	
	if is_server:
		server_broadcast_carets()

func _draw_carets():
	if not current_code_edit:
		return
	
	# draw all the carets on server
	if is_server:
		for id in connections:
			var client = connections[id]
			
			if client.current_script.path == current_script.resource_path:
				var caret_color = Color(client.color.r,client.color.g,client.color.b,0.75)
				
				var caret_line = client.current_script.caret_line
				var caret_column = client.current_script.caret_column
				
				var caret_pos = current_code_edit.get_pos_at_line_column(caret_line,caret_column)
				
				if caret_column != 0:
					caret_pos.x += 10
				
				draw_caret_at_pos(caret_pos,caret_color)
	
	if is_client:
		for caret in client_carets:
			if caret.path == current_script.resource_path and caret.id != client_id:
				var caret_color = Color(caret.color.r,caret.color.g,caret.color.b,0.75)
				
				var caret_line = caret.line
				var caret_column = caret.column
				
				var caret_pos = current_code_edit.get_pos_at_line_column(caret_line,caret_column)
				
				if caret_column != 0:
					caret_pos.x += 10
				
				draw_caret_at_pos(caret_pos,caret_color)

# draw a caret by given on screen position
func draw_caret_at_pos(caret_pos: Vector2, caret_color: Color):
	var font = current_code_edit.get_theme_font("font")
	var font_size = current_code_edit.get_theme_font_size("font_size")
	
	# Calculate caret dimensions
	var caret_width = 4  # You can adjust this value
	var line_height = font.get_height(font_size)
	
	caret_pos.x -= caret_width / 2
	
	# Create the caret rectangle
	var caret_rect = Rect2(caret_pos, Vector2(caret_width, -line_height))
	
	# Only draw if the caret is within the visible area
	if caret_rect.position.y >= 0 and caret_rect.position.y < current_code_edit.size.y:
		# Draw the custom caret
		current_code_edit.draw_rect(caret_rect, caret_color, true)

func _process(_delta: float) -> void:
	# server process
	if is_server:
		# check for connections
		if server.is_connection_available():
			# someone connected
			var connection = server.take_connection()
			# save their connection with a custom id
			var client_id = randi_range(111111111,999999999)
			connections[client_id] = {
				"connection": connection,
				"username":"Anonymous",
				"color": {
					"g":255,
					"r":255,
					"b":255
				},
				# current opened script
				"current_script":{
					"path":null,
					"caret_column":0,
					"caret_line":0,
				}
			}
			
			print_rich("[color=dark_gray]New connection from: ", connection.get_connected_host(),"[/color]")
			server_update_client_list()
			
			var msg = Message.new("client_id")
			msg.data.id = client_id
			
			server_send_message(connection,msg)
		
		# check for incoming data
		for id in connections.keys():
			var connection : StreamPeerTCP = connections[id].connection
			connection.poll()
			
			if connection.get_status() == StreamPeerTCP.STATUS_NONE or connection.get_status() == StreamPeerTCP.STATUS_ERROR:
				# client is disconnected
				print_rich("[color=dark_gray]client disconnected, ", connection.get_connected_host(),"[/color]")
				connections.erase(id)
				server_update_client_list()
			else:
				# client is still here, so receive the message
				if connection.get_available_bytes() > 0:
					var response = Message.new()
					response.from_json(connection.get_string())
					server_handle_response(id,response)
	
	# client process
	if is_client:
		client.poll()
		# while client is connecting
		if !client_connected:
			var status = client.get_status()
			# client connected
			if status == StreamPeerTCP.STATUS_CONNECTED:
				client_connected = true
				print_rich("[color=green]Connected to server![/color]")
				dock.name = "Live Collab (Connected)"
				# ui
				dock_connection_panel.hide()
				dock_client_panel.show()
				
				# send the username if its not empty
				if dock_username_input.text.strip_edges() != "":
					var message = Message.new("username_change")
					message.data.username = dock_username_input.text
					client_send_message(message)
					
				# request all project files
				client_send_message(Message.new("all_file_sync"))
				
				# send the caret color
				var msg = Message.new("user_color")
				msg.data.r = dock_user_color_input.color.r
				msg.data.g = dock_user_color_input.color.g
				msg.data.b = dock_user_color_input.color.b
				client_send_message(msg)
				
			# error
			elif status == StreamPeerTCP.STATUS_ERROR:
				print_rich("[color=red]Error connecting to server[/color]")
				client_connected = false
				client = StreamPeerTCP.new()
				dock_connection_panel.show()
				dock.name = "Live Collab"
		else:
			# check if client lost the connection to the server
			if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				stop_client()
				print_rich("[color=red]Client lost connection to the server. Stopping client[/color]")
				return
			
			# receive incoming data if there is some
			if client.get_available_bytes() > 0:
				# if the client is currently waiting for a file
				if client_receiving_file:
					receive_file_data()
				else:
					var response = Message.new()
					response.from_json(client.get_string())
					
					client_handle_response(response)

# handle the client messages to server
func server_handle_response(connection_id : int, response : Message):
	var client = connections[connection_id]
	# username change
	if response.type == "username_change":
		var old_username = client.username
		client.username = response.data.username
		print_rich("[color=dark_gray]",connection_id,"changed their username from ",old_username, " to ", response.data.username, "[/color]")
		server_update_client_list()
	# send them the files
	elif response.type == "all_file_sync":
		sync_all_files_with_connection(client.connection)
		print_rich("[color=dark_gray]",connection_id," requested all files[/color]")
	elif response.type == "caret_position":
		client.current_script.caret_line = response.data.line
		client.current_script.caret_column = response.data.column
		
		server_broadcast_carets()
		print_rich("[color=dark_gray]",connection_id," set their caret position[/color]")
	elif response.type == "user_color":
		var d = response.data
		var new_color = Color(d.r, d.g, d.b, 1)
		
		client.color = response.data
		server_update_client_list()
		print_rich("[color=dark_gray]",connection_id," changed their caret color to [/color]", new_color)
	elif response.type == "current_script_path":
		client.current_script.path = response.data.script_path
	else:
		# unknown message
		print_rich("[color=red]Unhandled response from client: [/color]", response.type)

# handle message to client from server
func client_handle_response(response : Message):
	# get ready for the file transmission
	if response.type == "file":
		start_file_reception(response)
	# handle the all the client usernames list
	elif response.type == "clients_list":
		client_update_client_list(response.data.list)
	elif response.type == "carets":
		client_carets = response.data.carets
	elif response.type == "client_id":
		client_id = response.data.id
	else:
		# unknown message
		print_rich("[color=red]Unhandled response from server: [/color]", response.type)

# clean up
func _exit_tree():
	# remove the ui dock
	remove_control_from_docks(dock)
	dock.free()
	
	# stop networking stuff
	if is_server:
		stop_server()
	
	if is_client:
		stop_client()
	
	if current_code_edit:
		current_code_edit.draw.disconnect(_draw_carets)
		current_code_edit.caret_changed.disconnect(_caret_changed)
	
	script_editor.editor_script_changed.disconnect(_on_script_changed)


# start the server
func start_server():
	# check if port is valid
	var PORT = dock_server_port_input.text.to_int()
	if PORT == 0:
		OS.alert("Invalid port")
		return
	
	# start the server
	var err = server.listen(PORT)
	if err != OK:
		print_rich("[color=red]Failed to start server: [/color]", err)
		return
	print_rich("[color=green]Server listening on port [/color]", PORT)
	is_server = true
	
	# ui
	dock.name = "Live Collab (Listening)"
	dock_connection_panel.hide()
	dock_server_panel.show()
	
	server_update_client_list()

func stop_server():
	# disconnect everyone
	for id in connections.keys():
		var connection = connections[id].connection
		connection.disconnect_from_host()
	
	# stop the server
	server.stop()
	
	# reset variables
	is_server = false
	dock_connection_panel.show()
	dock_server_panel.hide()
	dock.name = "Live Collab"

func start_client():
	# check if port is valid
	var PORT = dock_server_port_input.text.to_int()
	if PORT == 0:
		OS.alert("Invalid port")
		return
	
	# connect to the server
	var err = client.connect_to_host(dock_server_address_input.text, PORT)
	if err != OK:
		print_rich("[color=red]Failed to connect to server: [/color]", err)
		return
	print_rich("[color=dark_gray]Connecting to server...[/color]")
	is_client = true
	
	# ui
	dock_connection_panel.hide()
	dock.name = "Live Collab (Connecting)"

func stop_client():
	# disconnect from the server just in case
	client.disconnect_from_host()
	
	# reset variables
	is_client = false
	client_connected = false
	
	dock_connection_panel.show()
	dock_client_panel.hide()
	dock.name = "Live Collab"

# send message to server from client
func client_send_message(message : Message):
	if client_connected:
		client.put_string(message.to_json())
		print_rich("[color=dark_gray]Sent type", message.type, " to the server[/color]")
	else:
		print_rich("[color=red]Not connected to server[/color]")

# send message from server to a specific client
func server_send_message(connection : StreamPeerTCP, message : Message):
	connection.put_string(message.to_json())

# send message from server to all clients
func server_broadcast(message : Message):
	for id in connections.keys():
		var connection = connections[id].connection
		server_send_message(connection,message)

# get the ui elements, yes its freaky
func assign_ui_elements():
	dock_host_btn = dock.get_node("Connection panel/Host button")
	dock_connect_btn = dock.get_node("Connection panel/Connect button")
	dock_server_address_input = dock.get_node("Connection panel/Server address input")
	dock_server_port_input = dock.get_node("Connection panel/Server port input")
	dock_connection_panel = dock.get_node("Connection panel")
	dock_username_input = dock.get_node("Connection panel/Username input")
	dock_user_color_input = dock.get_node("Connection panel/user color")
	
	dock_server_panel = dock.get_node("Server panel")
	dock_server_stop_btn = dock.get_node("Server panel/stop server")
	dock_server_force_sync_btn = dock.get_node("Server panel/force sync")
	dock_server_client_list = dock.get_node("Server panel/client list")
	
	dock_client_panel = dock.get_node("Client panel")
	dock_client_stop_btn = dock.get_node("Client panel/stop client")
	dock_client_clients_list = dock.get_node("Client panel/client list")

# get an array of paths to all the files in the resources. can also exclude specified folders
func get_all_files_in_project(path: String = "res://", exclude_folders: Array = []) -> Array:
	var files = []
	var dir = DirAccess.open(path)
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			var full_path = path + "/" + file_name
			if dir.current_is_dir() and file_name != "." and file_name != "..":
				# Check if the directory is in the exclude list
				if file_name not in exclude_folders:
					files += get_all_files_in_project(full_path, [])
			else:
				files.append(full_path)
			file_name = dir.get_next()
		
		dir.list_dir_end()
	return files

# send a file to a specific client
func server_send_file_to_client(file_path : String,connection : StreamPeerTCP):
	
	# read the file
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		print_rich("[color=red]Failed to open file: [/color]", file_path)
		return

	var file_content = file.get_buffer(file.get_length())
	file.close()

	var file_name = file_path.get_file()
	var file_size = file_content.size()
	
	
	# Send file metadata first
	connection.put_string(JSON.stringify({
		"type":"file",
		"data":{
			"file_name":file_name,
			"file_size":file_size,
			"file_path":file_path
		}
	}))
	# now that the client is ready to receive the file, send the raw data
	connection.put_data(file_content)

	print_rich("[color=green]File sent to client: [/color]", file_path)

# broadcast a specific file
func server_send_file_to_all_clients(file_path: String):
	for id in connections.keys():
		var connection = connections[id].connection
		server_send_file_to_client(file_path,connection)

# send all files to everyone
func sync_all_files_with_everyone():
	var all_files = get_all_files_in_project("res://",[".godot"])
	for file in all_files:
		server_send_file_to_all_clients(file)

# send all files to a certain client
func sync_all_files_with_connection(connection : StreamPeerTCP):
	var all_files = get_all_files_in_project("res://",[".godot"])
	for file in all_files:
		server_send_file_to_client(file,connection)

# get ready to receive the files
func start_file_reception(metadata : Message):
	var parts = metadata.data
	# set all the variables
	client_file_name = parts.file_name
	client_file_size = int(parts.file_size)
	client_receiving_file = true
	client_received_size = 0
	client_file_data.clear()
	client_file_path = parts.file_path
	print_rich("[color=dark_gray]Starting to receive file: ", client_file_name, " (", client_file_size, " bytes)[/color]")

# receive the raw data
func receive_file_data():
	var chunk = client.get_data(min(1024, client_file_size - client_received_size))
	if chunk[0] == OK:
		client_file_data.append_array(chunk[1])
		client_received_size += chunk[1].size()
		
		if client_received_size >= client_file_size:
			save_received_file()
			client_receiving_file = false

func save_received_file():
	var dir = DirAccess.open("res://")
	if dir:
		# Ensure the directory exists
		var directory = client_file_path.get_base_dir()
		if not dir.dir_exists(directory):
			var err = dir.make_dir_recursive(directory)
			if err != OK:
				print_rich("[color=red]Failed to create directory: [/color]", directory)
				return
		var file = FileAccess.open(client_file_path, FileAccess.WRITE)
		if file:
			file.store_buffer(client_file_data)
			file.close()
			print_rich("[color=green]File saved: [/color]", client_file_path)
			
			# clear so it doesnt take up memory
			client_file_data.clear()
		else:
			print_rich("[color=red]Failed to save file: [/color]", client_file_path)
	else:
		print_rich("[color=red]Failed to access project directory[/color]")

# update the ui list on server, but also send the username list to all clients
func server_update_client_list(send_update_to_clients : bool = true):
	dock_server_client_list.clear()
	var client_list = []
	
	var server_name = dock_username_input.text
	if server_name.strip_edges() == "":
		server_name = "Anonymous"
	
	# add the server username too
	client_list.append({
			"username":server_name,
			"color": {
				"r":dock_user_color_input.color.r,
				"g":dock_user_color_input.color.g,
				"b":dock_user_color_input.color.b
			}
		})
	
	var gradient_texture = GradientTexture2D.new()
	gradient_texture.height = 15
	gradient_texture.width = 15
	
	var gradient = Gradient.new()
	gradient.offsets = [0,1]
	gradient.colors = [dock_user_color_input.color,dock_user_color_input.color]
	gradient_texture.gradient = gradient
	dock_server_client_list.add_item(server_name,gradient_texture)
	
	# show the usernames
	for id in connections:
		var client = connections[id]
		var client_color = Color(client.color.r,client.color.g,client.color.b)
		print(client_color)
		var gt = GradientTexture2D.new()
		gt.height = 15
		gt.width = 15
		
		var g = Gradient.new()
		g.offsets = [0,1]
		g.colors = [client_color,client_color]
		gt.gradient = g
		
		dock_server_client_list.add_item(client.username,gt)
		client_list.append({
			"username":client.username,
			"color": {
				"r":client.color.r,
				"g":client.color.g,
				"b":client.color.b
			}
		})
	
	# send the usernames
	var message = Message.new()
	message.type = "clients_list"
	message.data.list = client_list
	server_broadcast(message)


# show the usernames in the list
func client_update_client_list(list : Array):
	print_rich("[b]Client update list: ",list,"[/b]")
	dock_client_clients_list.clear()
	
	for client in list:
		
		var client_color = Color(client.color.r,client.color.g,client.color.b)
		print(client_color)
		var gt = GradientTexture2D.new()
		gt.height = 15
		gt.width = 15
		
		var g = Gradient.new()
		g.offsets = [0,1]
		g.colors = [client_color,client_color]
		gt.gradient = g
		
		dock_client_clients_list.add_item(client.username,gt)
