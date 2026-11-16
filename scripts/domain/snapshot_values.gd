extends RefCounted

static func number(value: Variant, minimum: float = 0.0) -> bool:
	return (value is int or value is float) and is_finite(value) and value >= minimum


static func integer(value: Variant, maximum: int) -> bool:
	return number(value) and value <= maximum and floor(value) == value


static func point(value: Variant) -> bool:
	return value is Array and value.size() == 2 and number(value[0], -1e20) \
		and number(value[1], -1e20) and absf(value[0]) <= 1e20 and absf(value[1]) <= 1e20

# JSON's decimal parser can round a double differently by one bit.
static func encode_real(value: float) -> String:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0, value)
	return bytes.hex_encode()


static func decode_real(value: Variant) -> float:
	if not value is String or value.length() != 16 or not value.is_valid_hex_number():
		return NAN
	var bytes: PackedByteArray = value.hex_decode()
	return bytes.decode_double(0) if bytes.size() == 8 else NAN
