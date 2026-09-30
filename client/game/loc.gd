extends RefCounted
## All user-facing strings of the menu and the HUD live here, so translating
## the game means adding one more dictionary. The language comes from the
## settings (`Settings.language`, default Czech). A missing key falls back to
## Czech, then to the key itself.

const Settings := preload("res://game/settings.gd")

const LANGUAGES := {"cs": "Čeština", "en": "English"}

const CS := {
	"title": "OpenRail",
	"subtitle": "Železniční dopravní simulace",
	"menu.new_game": "Nová hra",
	"menu.join": "Připojit k serveru",
	"menu.settings": "Nastavení",
	"menu.quit": "Konec",
	"menu.version": "Vývojová verze",
	"new.title": "Nová hra",
	"new.seed": "Seed mapy",
	"new.random": "Náhodný",
	"new.towns": "Počet měst",
	"new.start": "Začít",
	"join.title": "Připojit k serveru",
	"join.address": "Adresa",
	"join.port": "Port",
	"join.password": "Heslo",
	"join.name": "Jméno hráče",
	"join.fingerprint": "Otisk certifikátu (nepovinné)",
	"join.connect": "Připojit",
	"join.failed": "Připojení se nezdařilo: %s",
	"join.no_address": "Zadejte adresu serveru",
	"settings.title": "Nastavení",
	"settings.window": "Režim okna",
	"settings.windowed": "V okně",
	"settings.fullscreen": "Celá obrazovka",
	"settings.volume": "Hlavní hlasitost",
	"settings.language": "Jazyk",
	"common.cancel": "Zrušit",
	"common.close": "Zavřít",
	"common.ok": "OK",
	"hud.pause": "Pauza",
	"hud.speed": "Rychlost %dx",
	"hud.paused": "Pozastaveno",
	"hud.menu": "Menu",
	"hud.leave_title": "Zpět do menu",
	"hud.leave_text": "Opravdu odejít do hlavního menu? Neuložený postup se ztratí.",
	"hud.leave_yes": "Odejít",
	"hud.balance": "Zůstatek",
	"hud.date": "Datum",
	"hud.remote_speed": "Rychlost řídí server",
	"toast.no_money": "Nedostatek peněz",
	"toast.build_failed": "Stavba se nezdařila: %s",
	"town.label": "%s (%s obyv.)",
	"station.label": "%s obyv. | čeká %s",
	"station.waiting": "čeká %s",
	"train.load": "vlak %d: %d/%d",
	"lines.title": "Vlaky a linky",
	"lines.empty": "Zatím žádné vlaky. Použijte nástroj Vlak na kolejích.",
	"lines.train": "Vlak %d",
	"lines.editing": " (úprava)",
	"lines.show": "Ukázat",
	"lines.route": "Trasa",
	"lines.no_route": "Bez trasy (jezdí tam a zpět po trati %d)",
	"menu.disconnected_title": "Odpojeno od serveru",
	"menu.disconnected": "Spojení se serverem skončilo: %s",
	"tool.track": "Kolej",
	"tool.station": "Stanice",
	"tool.train": "Vlak",
	"tool.route": "Trasa",
	"tool.bulldoze": "Bourání",
	"tool.bulldoze_na": "Bourání zatím není k dispozici.",
	"tool.undo_stop": "Zpět zastávku",
	"tool.confirm_route": "Potvrdit trasu (Enter)",
	"node.station": "Stanice %d",
	"node.junction": "Uzel %d",
	"node.position": "Poloha: %d, %d m",
	"node.tracks": "Koleje: %d",
	"node.trains": "Vlaky: %s",
	"node.no_trains": "žádné",
	"hint.none": "Vyberte nástroj dole. WASD posouvá, kolečko přibližuje, prostřední tlačítko otáčí.",
	"hint.track_start": "Klikněte na místo nebo existující uzel a začněte kolej.",
	"hint.track_next": "Klikněte na další bod. Pravé tlačítko nebo Esc trať ukončí.",
	"hint.track_short": "Příliš krátké. Kolej musí mít aspoň %d m.",
	"hint.track_exists": "Mezi těmito uzly už kolej vede.",
	"hint.track_failed": "Kolej nelze postavit%s.",
	"hint.station": "Klikněte na uzel a udělejte z něj stanici.",
	"hint.station_no_node": "Klikněte na uzel koleje, ze kterého má být stanice.",
	"hint.station_exists": "Uzel %d už je stanice.",
	"hint.station_built": "Stanice %d postavena.",
	"hint.station_failed": "Stanici tu nelze postavit%s.",
	"hint.train": "Klikněte na kolej a postavte na ni vlak.",
	"hint.train_no_track": "Klikněte na kolej, kam se má vlak postavit.",
	"hint.train_failed": "Vlak nelze postavit%s.",
	"hint.train_track_taken": "Na této koleji už vlak je.",
	"hint.train_placed": "Vlak %d postaven. Nástrojem Trasa ho pošlete mezi stanice.",
	"hint.train_placed_any": "Vlak postaven. Nástrojem Trasa ho pošlete mezi stanice.",
	"hint.route_pick": "Klikněte na vlak (nebo ho vyberte v seznamu) a pak postupně na stanice.",
	"hint.route_stops": "Vlak %d: klikejte postupně na stanice (vybráno %d). Enter potvrdí.",
	"hint.route_not_station": "Uzel %d není stanice. Postavte ji nástrojem Stanice.",
	"hint.route_incomplete": "Trasa potřebuje vlak a aspoň dvě stanice.",
	"hint.route_rejected": "Trasa byla odmítnuta%s.",
	"hint.route_set": "Trasa vlaku %d nastavena. Vyberte další vlak nebo stiskněte Esc.",
	"hint.waiting": "Čekám na server...",
	"error.funds": "nedostatek peněz",
	"error.not_owner": "patří jinému hráči",
	"error.degenerate": "kolej musí spojovat dva různé body",
	"error.population": "neplatný počet obyvatel",
	"error.unknown_node": "uzel %s neexistuje",
	"error.unknown_track": "kolej %s neexistuje",
	"error.unknown_train": "vlak %s neexistuje",
	"error.not_station": "uzel %s není stanice",
	"error.occupied": "na koleji %s už vlak je",
	"error.not_connected": "nejste připojeni",
}

const EN := {
	"title": "OpenRail",
	"subtitle": "Railway transport simulation",
	"menu.new_game": "New game",
	"menu.join": "Join server",
	"menu.settings": "Settings",
	"menu.quit": "Quit",
	"menu.version": "Development build",
	"new.title": "New game",
	"new.seed": "Map seed",
	"new.random": "Random",
	"new.towns": "Number of towns",
	"new.start": "Start",
	"join.title": "Join server",
	"join.address": "Address",
	"join.port": "Port",
	"join.password": "Password",
	"join.name": "Player name",
	"join.fingerprint": "Certificate fingerprint (optional)",
	"join.connect": "Connect",
	"join.failed": "Connection failed: %s",
	"join.no_address": "Enter the server address",
	"settings.title": "Settings",
	"settings.window": "Window mode",
	"settings.windowed": "Windowed",
	"settings.fullscreen": "Fullscreen",
	"settings.volume": "Master volume",
	"settings.language": "Language",
	"common.cancel": "Cancel",
	"common.close": "Close",
	"common.ok": "OK",
	"hud.pause": "Pause",
	"hud.speed": "Speed %dx",
	"hud.paused": "Paused",
	"hud.menu": "Menu",
	"hud.leave_title": "Back to menu",
	"hud.leave_text": "Really leave to the main menu? Unsaved progress is lost.",
	"hud.leave_yes": "Leave",
	"hud.balance": "Balance",
	"hud.date": "Date",
	"hud.remote_speed": "The server controls the speed",
	"toast.no_money": "Not enough money",
	"toast.build_failed": "Could not build: %s",
	"town.label": "%s (pop. %s)",
	"station.label": "pop. %s | waiting %s",
	"station.waiting": "waiting %s",
	"train.load": "train %d: %d/%d",
	"lines.title": "Trains and lines",
	"lines.empty": "No trains yet. Use the Train tool on a track.",
	"lines.train": "Train %d",
	"lines.editing": " (editing)",
	"lines.show": "Show",
	"lines.route": "Route",
	"lines.no_route": "No route (shuttles on track %d)",
	"menu.disconnected_title": "Disconnected",
	"menu.disconnected": "The online game ended: %s",
	"tool.track": "Track",
	"tool.station": "Station",
	"tool.train": "Train",
	"tool.route": "Route",
	"tool.bulldoze": "Bulldoze",
	"tool.bulldoze_na": "Bulldoze is not available yet.",
	"tool.undo_stop": "Undo stop",
	"tool.confirm_route": "Confirm route (Enter)",
	"node.station": "Station %d",
	"node.junction": "Junction %d",
	"node.position": "Position: %d, %d m",
	"node.tracks": "Tracks: %d",
	"node.trains": "Trains: %s",
	"node.no_trains": "none",
	"hint.none": "Pick a tool below. WASD pans, wheel zooms, middle mouse rotates.",
	"hint.track_start": "Click a point or an existing node to start a track.",
	"hint.track_next": "Click to place the next point. Right click or Esc ends the line.",
	"hint.track_short": "Too short. Tracks need at least %d m.",
	"hint.track_exists": "There is already a track between those nodes.",
	"hint.track_failed": "Could not build that track%s.",
	"hint.station": "Click a node to turn it into a station.",
	"hint.station_no_node": "Click on a track node to make it a station.",
	"hint.station_exists": "Node %d is already a station.",
	"hint.station_built": "Station %d built.",
	"hint.station_failed": "Could not build a station there%s.",
	"hint.train": "Click a track to place a train.",
	"hint.train_no_track": "Click on a track to place a train.",
	"hint.train_failed": "Could not place a train%s.",
	"hint.train_track_taken": "That track already has a train.",
	"hint.train_placed": "Train %d placed. Use the Route tool to send it between stations.",
	"hint.train_placed_any": "Train placed. Use the Route tool to send it between stations.",
	"hint.route_pick": "Click a train (or pick one in the list), then choose stations in order.",
	"hint.route_stops": "Train %d: click stations in order (%d chosen). Enter confirms.",
	"hint.route_not_station": "Node %d is not a station. Build one with the Station tool.",
	"hint.route_incomplete": "A route needs a train and at least two stations.",
	"hint.route_rejected": "The route was rejected%s.",
	"hint.route_set": "Route set for train %d. Select another train or press Esc.",
	"hint.waiting": "Waiting for the server...",
	"error.funds": "not enough money",
	"error.not_owner": "that belongs to another player",
	"error.degenerate": "track must join two distinct points",
	"error.population": "invalid town population",
	"error.unknown_node": "node %s does not exist",
	"error.unknown_track": "track %s does not exist",
	"error.unknown_train": "train %s does not exist",
	"error.not_station": "node %s is not a station",
	"error.occupied": "track %s already has a train",
	"error.not_connected": "not connected",
}


## Translated string for `key`; `args` fill the `%` placeholders.
static func t(key: String, args: Array = []) -> String:
	var table: Dictionary = EN if Settings.language == "en" else CS
	var text: String = table.get(key, CS.get(key, key))
	return text % args if not args.is_empty() else text


## Simulation error texts (English, from `SimWorld.last_error()` or the
## server) mapped to their keys; `%s` captures an id.
const ERRORS := {
	"not enough money": "error.funds",
	"that belongs to another player": "error.not_owner",
	"track must join two distinct points": "error.degenerate",
	"invalid town population": "error.population",
	"not connected": "error.not_connected",
	"node %s does not exist": "error.unknown_node",
	"track %s does not exist": "error.unknown_track",
	"train %s does not exist": "error.unknown_train",
	"node %s is not a station": "error.not_station",
	"track %s already has a train": "error.occupied",
}


## Translates a simulation error text; unknown texts come back unchanged.
static func error(text: String) -> String:
	for pattern: String in ERRORS:
		var parts := pattern.split("%s")
		if parts.size() == 1:
			if text == pattern:
				return t(ERRORS[pattern])
		elif text.begins_with(parts[0]) and text.ends_with(parts[1]) \
				and text.length() > parts[0].length() + parts[1].length():
			var id := text.substr(parts[0].length(), text.length() - parts[0].length() - parts[1].length())
			if id.is_valid_int():
				return t(ERRORS[pattern], [id])
	return text


## Whole number with thousands separators: 2000000 -> "2 000 000".
static func number(value: int) -> String:
	var sep := "," if Settings.language == "en" else " "
	var digits := str(absi(value))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += sep
		out += digits[i]
	return ("-" if value < 0 else "") + out


## Money as shown in the HUD: "2 000 000 $".
static func money(value: int) -> String:
	return number(value) + " $"
