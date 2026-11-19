extends RefCounted
## Blueprint coordinates identify the bottom-left cell of each square block.

const LEGACY_VERSION := 1
const VERSION := 2
const MAX_WIDTH := 59
const MAX_HEIGHT := 30
const MAX_BLOCKS := 900
const ALLOWED_SIZES := [1, 2, 4]


static func validate(data: Variant) -> Dictionary:
	if not data is Dictionary:
		return {"error": "Expected blueprint version 1 or 2 and a blocks array."}
	var raw_version: Variant = data.get("version")
	if not _integer(raw_version) or int(raw_version) not in [LEGACY_VERSION, VERSION] \
			or not data.get("blocks") is Array:
		return {"error": "Expected blueprint version 1 or 2 and a blocks array."}
	var version := int(raw_version)
	var blocks: Array = data.blocks
	if blocks.is_empty() or blocks.size() > MAX_BLOCKS:
		return {"error": "The blueprint must contain between 1 and %d blocks." % MAX_BLOCKS}
	var occupied := {}
	var ordered: Array[Dictionary] = []
	var needs_v2 := false
	for block in blocks:
		if not block is Dictionary:
			return {"error": "Each block must be an object."}
		var x: Variant = block.get("x")
		var y: Variant = block.get("y")
		var size: Variant = block.get("size", 1)
		if not _integer(x) or not _integer(y) or not _integer(size) \
				or x < 0 or y < 0 or x >= MAX_WIDTH or y >= MAX_HEIGHT:
			return {"error": "Block coordinates must be integers within the 59 × 30 grid."}
		if block.get("type", "stone") != "stone" or int(size) not in ALLOWED_SIZES \
				or (version == LEGACY_VERSION and int(size) != 1):
			return {"error": "Version 1 supports stone 1×1 blocks; version 2 supports stone sizes 1, 2, and 4."}
		if x + size > MAX_WIDTH or y + size > MAX_HEIGHT:
			return {"error": "Block at (%d, %d) extends beyond the 59 × 30 grid." % [x, y]}
		for dy in range(int(size)):
			for dx in range(int(size)):
				var cell := Vector2i(int(x) + dx, int(y) + dy)
				if occupied.has(cell):
					return {"error": "Blocks overlap at (%d, %d)." % [cell.x, cell.y]}
				occupied[cell] = true
		ordered.append({"x": int(x), "y": int(y), "type": "stone", "size": int(size)})
		needs_v2 = needs_v2 or size > 1
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x
	)
	return {"version": VERSION if needs_v2 else version, "blocks": ordered}


static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and floor(float(value)) == float(value)
