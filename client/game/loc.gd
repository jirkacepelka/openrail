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
	"join.not_ready": "Online zatím není hotové",
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
	"join.not_ready": "Online is not ready yet",
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
}


## Translated string for `key`; `args` fill the `%` placeholders.
static func t(key: String, args: Array = []) -> String:
	var table: Dictionary = EN if Settings.language == "en" else CS
	var text: String = table.get(key, CS.get(key, key))
	return text % args if not args.is_empty() else text


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
