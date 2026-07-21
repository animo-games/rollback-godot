## Pluggable per-provider input serializer for RollbackNetSession. When a
## session has an input_codec, input packets go over the wire as a compact
## PackedByteArray instead of the default variant-Dictionary RPC. No codec =
## legacy Dictionary path (unchanged).
##
## Determinism contract: the session round-trips every locally-sampled input
## through canonicalize() BEFORE storing it, so the local simulation uses the
## exact value the peer decodes. encode()/decode() may be lossy (e.g. quantize)
## as long as decode(encode(x)) is idempotent and identical on every peer.
class_name RollbackInputCodec
extends RefCounted


## Serialize one provider's input snapshot to bytes (fixed or variable size).
func encode_input(_input: Dictionary) -> PackedByteArray:
	return PackedByteArray()


## Deserialize one provider's input starting at byte `offset`. Return
## {"input": Dictionary, "next": int} where next is the offset just past the
## bytes consumed.
func decode_input(_buf: PackedByteArray, _offset: int) -> Dictionary:
	return {"input": {}, "next": _offset}


## The value the session stores locally so its sim matches the wire. Default is
## a full encode/decode round-trip; override only for a cheaper equivalent.
func canonicalize(input: Dictionary) -> Dictionary:
	var decoded := decode_input(encode_input(input), 0)
	return decoded["input"] as Dictionary
