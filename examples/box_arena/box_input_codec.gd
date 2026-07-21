## Example RollbackInputCodec for the {mx, my, b} box input: mx/my as signed int8
## (±1.0 -> ±127), b as a u8 button mask. Digital input round-trips exactly.
## Subclass RollbackInputCodec like this for your own input dictionary shape.
## No class_name on purpose (see rollback_box.gd) — the online template preloads it.
extends RollbackInputCodec

const FRAME_SIZE := 3


func encode_input(input: Dictionary) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(FRAME_SIZE)
	buf[0] = _enc(input.get("mx", 0.0))
	buf[1] = _enc(input.get("my", 0.0))
	buf[2] = int(input.get("b", 0)) & 0xFF
	return buf


func decode_input(buf: PackedByteArray, offset: int) -> Dictionary:
	if offset + FRAME_SIZE > buf.size():
		return {"input": {"mx": 0.0, "my": 0.0, "b": 0}, "next": offset + FRAME_SIZE}
	return {
		"input": {"mx": _dec(buf[offset]), "my": _dec(buf[offset + 1]), "b": int(buf[offset + 2])},
		"next": offset + FRAME_SIZE,
	}


func _enc(v: Variant) -> int:
	var f := clampf(float(v) if (v is float or v is int) else 0.0, -1.0, 1.0)
	return clampi(int(round(f * 127.0)), -127, 127) & 0xFF


func _dec(b: int) -> float:
	return float(b if b < 128 else b - 256) / 127.0
