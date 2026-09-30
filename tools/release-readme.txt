OpenRail (unsigned pre-release build)
=====================================

ENGLISH

Run the game
  Windows: unzip the whole folder, then double-click OpenRail.exe. Keep
  openrail_gdext.dll next to it. The build is not code signed, so Windows
  SmartScreen may warn you: click "More info", then "Run anyway".
  Linux: extract the archive and run ./OpenRail.x86_64 (keep
  libopenrail_gdext.so next to it).

Host a multiplayer server
  1. Copy server.example.toml to server.toml and edit it (port, password,
     max players).
  2. Run: openrail-server --config server.toml
     (Windows: openrail-server.exe --config server.toml)
  3. Open the game port (UDP, default 7878) on your firewall or router.
  4. The server prints a certificate fingerprint on first start; players
     use it to verify they connect to your server.

Source code and issues: https://github.com/jirkacepelka/openrail
Licence: MIT (see LICENSE)


CESKY

Spusteni hry
  Windows: rozbalte celou slozku a spustte OpenRail.exe. Soubor
  openrail_gdext.dll musi zustat vedle nej. Sestaveni neni podepsane
  certifikatem, proto Windows SmartScreen muze zobrazit varovani: kliknete
  na "Dalsi informace" (More info) a pak na "Presto spustit" (Run anyway).
  Linux: rozbalte archiv a spustte ./OpenRail.x86_64 (soubor
  libopenrail_gdext.so nechte vedle nej).

Vlastni server pro hru vice hracu
  1. Zkopirujte server.example.toml na server.toml a upravte ho (port, heslo,
     max. pocet hracu).
  2. Spustte: openrail-server --config server.toml
     (Windows: openrail-server.exe --config server.toml)
  3. Na firewallu nebo routeru povolte herni port (UDP, vychozi 7878).
  4. Pri prvnim startu server vypise otisk certifikatu; hraci podle nej
     overi, ze se pripojuji k vasemu serveru.

Zdrojove kody a hlaseni chyb: https://github.com/jirkacepelka/openrail
Licence: MIT (viz LICENSE)
