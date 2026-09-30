extends RefCounted
## Shared constants for the build tools. Kept in its own script so that both
## the controller and the UI can use it without preloading each other.

enum Tool { NONE, TRACK, STATION, TRAIN, ROUTE, BULLDOZE }

const NAMES := {
	Tool.NONE: "Select",
	Tool.TRACK: "Track",
	Tool.STATION: "Station",
	Tool.TRAIN: "Train",
	Tool.ROUTE: "Route",
	Tool.BULLDOZE: "Bulldoze",
}
