@tool
extends EditorPlugin

var dock

var undo_redo : EditorUndoRedoManager

# server and client.
var server := TCPServer.new()
var is_server := false

var client := StreamPeerTCP.new()
var is_client := false
var client_connected := false

var client_receiving_file := false
var client_file_name := ""
var client_file_size := 0
var client_received_size := 0
var client_file_data := PackedByteArray()
var client_file_path := ""

var connections := {}

# ui elements
var dock_connection_panel : Control
var dock_host_btn : Button
var dock_connect_btn : Button
var dock_server_port_input : LineEdit
var dock_server_address_input : LineEdit
var dock_username_input : LineEdit

var dock_server_panel : Control
var dock_server_stop_btn : Button
var dock_server_force_sync_btn : Button
var dock_server_client_list : ItemList

var dock_client_panel : Control
var dock_client_stop_btn : Button

func _enter_tree():
	dock = preload("res://addons/godot_collaboration/dock.tscn").instantiate()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL,dock)
	
	undo_redo = get_undo_redo()
	undo_redo.history_changed.connect(_on_history_changed)
	
	assign_ui_elements()
	
	dock_host_btn.connect("pressed",start_server)
	dock_connect_btn.connect("pressed",start_client)
	
	dock_server_stop_btn.connect("pressed",stop_server)
	dock_server_force_sync_btn.connect("pressed",sync_all_files_with_everyone)
	
	dock_client_stop_btn.connect("pressed",stop_client)

func _process(_delta: float) -> void:
	
	if is_server:
		# check for connections
		if server.is_connection_available():
			var connection = server.take_connection()
			connections[randi_range(111111111,999999999)] = {
				"connection": connection,
				"username":"Anonymous"
			}
			print_rich("[color=dark_gray]New connection from: ", connection.get_connected_host(),"[/color]")
			#sync_all_files_with_connection(connection)
		
		# check for data
		for id in connections.keys():
			var connection : StreamPeerTCP = connections[id].connection
			
			if connection.get_status() == StreamPeerTCP.STATUS_NONE or connection.get_status() == StreamPeerTCP.STATUS_ERROR:
				print_rich("[color=dark_gray]client disconnected, ", connection.get_connected_host(),"[/color]")
				connections.erase(id)
			else:
				if connection.get_available_bytes() > 0:
					var response = JSON.parse_string(connection.get_string())
					server_handle_response(id,response)
		
		dock_server_client_list.clear()
		for id in connections:
			var client = connections[id]
			dock_server_client_list.add_item(client.username)
			
			
		
	if is_client:
		client.poll()
		if !client_connected:
			var status = client.get_status()
			if status == StreamPeerTCP.STATUS_CONNECTED:
				client_connected = true
				print_rich("[color=green]Connected to server![/color]")
				dock.name = "Live Collab (Connected)"
				dock_connection_panel.hide()
				dock_client_panel.show()
				if dock_username_input.text.strip_edges() != "":
					client_send_message("username_change",{
						"username":dock_username_input.text
					})
				
			elif status == StreamPeerTCP.STATUS_ERROR:
				print_rich("[color=red]Error connecting to server[/color]")
				client_connected = false
				client = StreamPeerTCP.new()
				dock_connection_panel.show()
				dock.name = "Live Collab"
		else:
			if client.get_available_bytes() > 0:
				if client_receiving_file:
					receive_file_data()
				else:
					var response = JSON.parse_string(client.get_string())
					client_handle_response(response)

func server_handle_response(connection_id, response):
	if response["type"] == "username_change":
		var old_username = connections[connection_id].username
		connections[connection_id].username = response["data"].username
		print_rich("[color=dark_gray]",connection_id,"changed their username from ",old_username, " to ", response["data"].username, "[/color]")
	elif response["type"] == "all_file_sync":
		sync_all_files_with_connection(connections[connection_id].connection)
		print_rich("[color=dark_gray]",connection_id," requested all files[/color]")
	else:
		print_rich("[color=red]Unhandled response from client: [/color]", response)

func client_handle_response(response):
	if response["type"] == "file":
		start_file_reception(response)
	else:
		print_rich("[color=red]Unhandled response from server: [/color]", response)

func _on_history_changed():
	pass

func _exit_tree():
	remove_control_from_docks(dock)
	dock.free()
	
	if is_server:
		stop_server()
	
	if is_client:
		stop_client()


func start_server():
	var PORT = dock_server_port_input.text.to_int()
	if PORT == 0:
		OS.alert("Invalid port")
		return
	
	var err = server.listen(PORT)
	if err != OK:
		print_rich("[color=red]Failed to start server: [/color]", err)
		return
	print_rich("[color=green]Server listening on port [/color]", PORT)
	is_server = true
	dock.name = "Live Collab (Listening)"
	
	dock_connection_panel.hide()
	dock_server_panel.show()

func stop_server():
	for id in connections.keys():
		var connection = connections[id].connection
		connection.disconnect_from_host()
	server.stop()
	is_server = false
	dock_connection_panel.show()
	dock_server_panel.hide()
	dock.name = "Live Collab"

func start_client():
	var PORT = dock_server_port_input.text.to_int()
	if PORT == 0:
		OS.alert("Invalid port")
		return
	
	var err = client.connect_to_host(dock_server_address_input.text, PORT)
	if err != OK:
		print_rich("[color=red]Failed to connect to server: [/color]", err)
		return
	print_rich("[color=dark_gray]Connecting to server...[/color]")
	is_client = true
	
	dock_connection_panel.hide()
	dock.name = "Live Collab (Connecting)"

func stop_client():
	client.disconnect_from_host()
	is_client = false
	client_connected = false
	
	dock_connection_panel.show()
	dock_client_panel.hide()
	dock.name = "Live Collab"


func client_send_message(type: String,data: Dictionary):
	if client_connected:
		client.put_string(JSON.stringify({
			"type":type,
			"data":data
		}))
		print_rich("[color=dark_gray]Sent type", type, " to the server[/color]")
	else:
		print_rich("[color=red]Not connected to server[/color]")

func assign_ui_elements():
	dock_host_btn = dock.get_node("Connection panel/Host button")
	dock_connect_btn = dock.get_node("Connection panel/Connect button")
	dock_server_address_input = dock.get_node("Connection panel/Server address input")
	dock_server_port_input = dock.get_node("Connection panel/Server port input")
	dock_connection_panel = dock.get_node("Connection panel")
	dock_username_input = dock.get_node("Connection panel/Username input")
	
	dock_server_panel = dock.get_node("Server panel")
	dock_server_stop_btn = dock.get_node("Server panel/stop server")
	dock_server_force_sync_btn = dock.get_node("Server panel/force sync")
	dock_server_client_list = dock.get_node("Server panel/client list")
	
	dock_client_panel = dock.get_node("Client panel")
	dock_client_stop_btn = dock.get_node("Client panel/stop client")


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

func server_send_file_to_client(file_path : String,connection : StreamPeerTCP):
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		print_rich("[color=red]Failed to open file: [/color]", file_path)
		return

	var file_content = file.get_buffer(file.get_length())
	file.close()

	var file_name = file_path.get_file()
	var file_size = file_content.size()
	
	# Send file metadata
	connection.put_string(JSON.stringify({
		"type":"file",
		"data":{
			"file_name":file_name,
			"file_size":file_size,
			"file_path":file_path
		}
	}))

	connection.put_data(file_content)

	print_rich("[color=green]File sent to client: [/color]", file_path)

func server_send_file_to_all_clients(file_path: String):
	for id in connections.keys():
		var connection = connections[id].connection
		server_send_file_to_client(file_path,connection)

func sync_all_files_with_everyone():
	var all_files = get_all_files_in_project("res://",[".godot"])
	for file in all_files:
		server_send_file_to_all_clients(file)

func sync_all_files_with_connection(connection : StreamPeerTCP):
	var all_files = get_all_files_in_project("res://",[".godot"])
	for file in all_files:
		server_send_file_to_client(file,connection)

func start_file_reception(metadata):
	var parts = metadata.data
	client_file_name = parts.file_name
	client_file_size = int(parts.file_size)
	client_receiving_file = true
	client_received_size = 0
	client_file_data.clear()
	client_file_path = parts.file_path
	print_rich("[color=dark_gray]Starting to receive file: ", client_file_name, " (", client_file_size, " bytes)[/color]")

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
		else:
			print_rich("[color=red]Failed to save file: [/color]", client_file_path)
	else:
		print_rich("[color=red]Failed to access project directory[/color]")
