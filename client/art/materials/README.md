# Hand-tuned materials

ArtStyle replaces any imported material whose name starts with `M_` by the
file of the same name in this folder, if it exists. For example, a glTF
material `M_Loco_Body` is replaced by `M_Loco_Body.tres`.

To make one: in Godot create a new ShaderMaterial, set its shader to
`res://art/shaders/painterly.gdshader`, set `albedo_texture` and turn on
`use_uv_texture`, tune the parameters, and save it here under the material's
name. Materials without a file here are converted automatically.
