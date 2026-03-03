extends Node2D

export var CYCLE_TIME = 10.0
export var TRANSITION_DURATION = 0.6
const FULL_HEAL_AMOUNT = -1000000.0
const HEAL_CAP = 1000.0
const DEBUG = true


const WHITELIST_SYSTEMS = [
	"SYSTEM_EMD14",
	"SYSTEM_EMD17RF",
	"SYSTEM_RAILTOR",
	"SYSTEM_CL150",
	"SYSTEM_CL600P",
	"SYSTEM_IROH",
	"SYSTEM_EINAT",
	"SYSTEM_NANI",
	"SYSTEM_MWG",
	"SYSTEM_ACTEMD14",
	"SYSTEM_ACL200P",
	#"SYSTEM_MWTIGHTBEAM"
]

const PROXY_PROPS = [
	"powerDraw", "thrust", "mass", "command",
	"gimbalLimit", "rotationSpeed"
]

const NODEPATH_PROPS = ["weaponPath", "pivotPath", "audioPath", "lightPath"]


#STATE
var candidates = []
var cached_scenes = {} # Preloaded weapon scenes (path -> PackedScene)
var current_candidate_idx = -1
var current_weapon_instance = null
var timer = 0.0
var shuffle_bag = []
var transitioning = false
var transition_tween: Tween

var ship
var slot
var key

#PROXY PROPERTIES
var systemName = "SYSTEM_MIMIC_GUN"
var powerDraw = 0.0
var thrust = 0.0
var mass = 0
var command = "w"

# MimicGun's own repair values
var inspection = true
export var repairFixPrice = 50000
export var repairFixTime = 8
export var repairReplacementPrice = 200000
export var repairReplacementTime = 16
var enabled = true setget setEnabled
export var rotationSpeed = 1.0
export var gimbalLimit = 0.0

# HUD weapon display
var weapon_display_node: Node2D
var cached_hud_label = null


func _ready():
	if DEBUG: Debug.l("[MimicGun] _ready called")
	randomize()
	
	var p = get_parent()
	while p:
		if p is RigidBody2D:
			ship = p
			break
		p = p.get_parent()
	
	if get_parent():
		slot = get_parent()
	
	key = (slot.name if slot else "WeaponSlot") + "_" + systemName
	
	if DEBUG: Debug.l("[MimicGun] ship=%s slot=%s key=%s" % [str(ship), str(slot), str(key)])
	
	if slot:
		for child in slot.get_children():
			if child is InstancePlaceholder and child.name in WHITELIST_SYSTEMS:
				candidates.append(child)
	
	# Fallback if slot somehow has none
	if candidates.empty():
		for child in get_children():
			if child is InstancePlaceholder and child.name in WHITELIST_SYSTEMS:
				candidates.append(child)
	
	if DEBUG: Debug.l("[MimicGun] Placeholders found: %s" % candidates.size())
	
	for c in candidates:
		var path = c.get_instance_path()
		if not path in cached_scenes:
			var loaded_scn = load(path)
			if loaded_scn:
				cached_scenes[path] = loaded_scn
			else:
				if DEBUG: Debug.l("[MimicGun] WARNING: Failed to load scene for placeholder %s at path: %s" % [c.name, path])
	if DEBUG: Debug.l("[MimicGun] Preloaded %s weapon scenes" % cached_scenes.size())
	
	transition_tween = Tween.new()
	add_child(transition_tween)
	
	cycle_weapon()


func _process(delta):
	if not enabled:
		return
	
	timer -= delta
	if timer <= 0:
		timer = CYCLE_TIME
		cycle_weapon()


func cycle_weapon():
	if candidates.empty():
		return
	
	if shuffle_bag.empty():
		for i in range(candidates.size()):
			shuffle_bag.append(i)
		shuffle_bag.shuffle()
		# Avoid immediate repeat
		if candidates.size() > 1 and shuffle_bag.back() == current_candidate_idx:
			var temp = shuffle_bag[0]
			shuffle_bag[0] = shuffle_bag.back()
			shuffle_bag[shuffle_bag.size() - 1] = temp
	
	var next_idx = shuffle_bag.pop_back()
	current_candidate_idx = next_idx
	var placeholder = candidates[current_candidate_idx]
	
	transitioning = true
	if DEBUG: Debug.l("[MimicGun] === CYCLE START ===")
	
	if current_weapon_instance and is_instance_valid(current_weapon_instance):
		if DEBUG: Debug.l("[MimicGun] Removing: %s" % current_weapon_instance.name)
		current_weapon_instance.set_physics_process(false)
		current_weapon_instance.set_process(false)
		if "targetPower" in current_weapon_instance:
			current_weapon_instance.targetPower = 0
		current_weapon_instance.queue_free()
		current_weapon_instance = null
	
	# Load and instance new weapon
	var scene_path = placeholder.get_instance_path()
	var stored_props = placeholder.get_stored_values(true)
	var scn = cached_scenes.get(scene_path)
	
	if not scn:
		if DEBUG: Debug.l("[MimicGun] ERROR: Scene not in cache: %s" % scene_path)
		timer = 0.1
		transitioning = false
		return
	
	var inst = scn.instance()
	var prefix = "../" + placeholder.name + "/"
	
	# Apply placeholder overrides with NodePath sanitization
	if stored_props:
		for prop in stored_props:
			var val = stored_props[prop]
			val = _sanitize_nodepath(val, prefix)
			inst.set(prop, val)
	
	# Sanitize scene-default NodePaths
	for prop in NODEPATH_PROPS:
		if prop in inst:
			inst.set(prop, _sanitize_nodepath(inst.get(prop), prefix))
	
	if "ship" in inst: inst.ship = ship
	if "slot" in inst: inst.slot = slot
	if "key" in inst: inst.key = key
	if "aged" in inst: inst.aged = true
	if "systemName" in inst: inst.systemName = systemName
	if "slotName" in inst: inst.slotName = slot
	if "specialFuelLimit" in inst and "specialFuel" in inst:
		inst.specialFuel = inst.specialFuelLimit
	if "myOffset" in inst and ship:
		inst.myOffset = ship.to_local(global_position)
	
	var real_slot = slot
	slot = null
	add_child(inst)
	slot = real_slot
	
	# Heal the newly added instance immediately to prevent 1-frame gaps
	if ship and key:
		for damage_type in ["wear", "bent", "focus", "choke", "pump"]:
			ship.changeSystemDamage(key, damage_type, FULL_HEAL_AMOUNT, HEAL_CAP)
	
	if "slot" in inst: inst.slot = real_slot
	if "key" in inst: inst.key = key
	
	current_weapon_instance = inst
	inst.visible = true
	if "enabled" in inst: inst.enabled = enabled
	
	inst.modulate.a = 0.0
	transition_tween.interpolate_property(inst, "modulate:a", 0.0, 1.0, TRANSITION_DURATION, Tween.TRANS_CUBIC, Tween.EASE_OUT)
	transition_tween.start()
	
	_update_proxy_stats(inst)
	
	# Update HUD weapon display
	_update_weapon_display(placeholder.name)
	
	if DEBUG: Debug.l("[MimicGun] Switched to: %s" % placeholder.name)
	
	call_deferred("_check_stability", inst, placeholder.name)
	transitioning = false


func _update_weapon_display(weapon_system_name: String):
	var translated_name = tr(weapon_system_name)
	
	if not weapon_display_node or not is_instance_valid(weapon_display_node):
		if not ship:
			return
		
		weapon_display_node = Node2D.new()
		weapon_display_node.name = "MimicWeapon_" + str(get_instance_id())
		weapon_display_node.set_script(preload("res://MimicGun/weapons/WeaponDisplayNode.gd"))
		weapon_display_node.systemName = translated_name
		add_child(weapon_display_node)
		
		call_deferred("_register_weapon_display_in_systemnodes")
	else:
		# Update existing display node
		weapon_display_node.systemName = translated_name
	
	call_deferred("_update_hud_label", weapon_display_node.name, translated_name)


var _registration_attempted = false

func _register_weapon_display_in_systemnodes():
	if _registration_attempted:
		return

	if not ship or not weapon_display_node or not is_instance_valid(weapon_display_node):
		return

	if not "systemNodes" in ship:
		return

	if ship.systemNodes.size() == 0:
		if ship.has_signal("systemPoll") and not ship.is_connected("systemPoll", self , "_on_system_poll"):
			ship.connect("systemPoll", self , "_on_system_poll", [], CONNECT_ONESHOT)
		return

	var my_slot = get_parent()
	var my_index = -1
	for i in range(ship.systemNodes.size()):
		var node = ship.systemNodes[i]
		if node == my_slot or node == self:
			my_index = i
			break

	if my_index != -1:
		if ship.systemNodes.find(weapon_display_node) == -1:
			ship.systemNodes.insert(my_index + 1, weapon_display_node)
			if DEBUG: Debug.l("[MimicGun] Inserted weapon display at index %s" % (my_index + 1))
	else:
		if ship.systemNodes.find(weapon_display_node) == -1:
			ship.systemNodes.append(weapon_display_node)
			if DEBUG: Debug.l("[MimicGun] Fallback: appended weapon display to systemNodes")
	_registration_attempted = true


func _on_system_poll():
	call_deferred("_register_weapon_display_in_systemnodes")


func _update_hud_label(node_id: String, new_text: String):
	if not ship:
		return
	
	if cached_hud_label and is_instance_valid(cached_hud_label):
		cached_hud_label.text = new_text.to_upper()
		return
	
	var hud = ship.get_node_or_null("Hud")
	if not hud:
		return
	var label = _find_hud_label(hud, node_id)
	if label:
		cached_hud_label = label
		cached_hud_label.text = new_text.to_upper()


func _find_hud_label(node, node_id: String):
	if "objects" in node and node.objects is Dictionary:
		if node.objects.has(node_id):
			var entry = node.objects[node_id]
			if "label" in entry and entry.label and is_instance_valid(entry.label):
				return entry.label
	
	for child in node.get_children():
		var result = _find_hud_label(child, node_id)
		if result:
			return result
	return null


func _check_stability(inst, weapon_name):
	yield (get_tree(), "idle_frame")
	if not is_instance_valid(self ): return
	if not is_instance_valid(inst):
		if DEBUG: Debug.l("[MimicGun] CRITICAL: %s deleted itself!" % weapon_name)
		timer = 0.1
	else:
		if DEBUG: Debug.l("[MimicGun] Stability OK: %s" % weapon_name)


func _sanitize_nodepath(val, prefix):
	if val is NodePath:
		var s = str(val)
		if s.begins_with(prefix):
			return NodePath(s.replace(prefix,""))
	return val


func _update_proxy_stats(inst):
	for prop in PROXY_PROPS:
		if prop in inst:
			set(prop, inst.get(prop))
	
	if not ("gimbalLimit" in inst):
		gimbalLimit = 0.0


func setEnabled(how):
	enabled = how
	if current_weapon_instance and "enabled" in current_weapon_instance:
		current_weapon_instance.enabled = how


#PROXY METHODS


func boresight():
	return current_weapon_instance.boresight() if current_weapon_instance else null


func shouldFire():
	if transitioning:
		return false
	return current_weapon_instance.shouldFire() if current_weapon_instance else false


func getStatus():
	return current_weapon_instance.getStatus() if current_weapon_instance else null


func getPower():
	return current_weapon_instance.getPower() if current_weapon_instance else 0.0


func fire(p):
	if transitioning or not current_weapon_instance:
		return
	if "ship" in current_weapon_instance:
		var s = current_weapon_instance.ship
		if not s or not is_instance_valid(s) or ("setup" in s and not s.setup):
			return
	current_weapon_instance.fire(p)


func getPowerDraw():
	if current_weapon_instance and "powerDraw" in current_weapon_instance:
		return current_weapon_instance.powerDraw
	return powerDraw


func getTuneables():
	# Hide from tuning menu
	return {}


func _exit_tree():
	if weapon_display_node and is_instance_valid(weapon_display_node):
		if ship and is_instance_valid(ship):
			if "systemNodes" in ship and weapon_display_node in ship.systemNodes:
				ship.systemNodes.erase(weapon_display_node)
				if DEBUG: Debug.l("[MimicGun] Removed weapon display from systemNodes")
		weapon_display_node.queue_free()
	weapon_display_node = null
	cached_hud_label = null
