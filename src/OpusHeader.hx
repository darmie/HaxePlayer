/* Header contents:
	- "OpusHead" (64 bits)
	- version number (8 bits)
	- Channels C (8 bits)
	- Pre-skip (16 bits)
	- Sampling rate (32 bits)
	- Gain in dB (16 bits, S7.8)
	- Mapping (8 bits, 0=single stream (mono/stereo) 1=Vorbis mapping,
				 2..254: reserved, 255: multistream with no mapping)

	- if (mapping != 0)
		 - N = totel number of streams (8 bits)
		 - M = number of paired streams (8 bits)
		 - C times channel origin
			  - if (C<2*M)
				 - stream = byte/2
				 - if (byte&0x1 == 0)
					 - left
				   else
					 - right
			  - else
				 - stream = byte-M
 */

import haxe.io.UInt8Array;
import cpp.Pointer;
import cpp.Reference;
import cpp.UInt8;
import cpp.RawPointer;
import cpp.Int16;
import cpp.UInt16;
import cpp.UInt32;
import haxe.io.Bytes;

using StringTools;

typedef Packet = {
	?data:RawPointer<UInt8>,
	?maxlen:Int,
	?pos:Int
}

typedef ROPacket = {
	?data:RawPointer<UInt8>,
	?maxlen:Int,
	?pos:Int
}

function write_uint32(p:Packet, val:UInt32):Int {
	if (p.pos > p.maxlen - 4)
		return 0;
    
	Pointer.fromRaw(p.data).setAt(p.pos, (val) & 0xFF);
	Pointer.fromRaw(p.data).setAt(p.pos + 1, (val >> 8) & 0xFF);
	Pointer.fromRaw(p.data).setAt(p.pos + 2, (val >> 16) & 0xFF);
	Pointer.fromRaw(p.data).setAt(p.pos + 3, (val >> 24) & 0xFF);
	p.pos += 4;
	return 1;
}

function write_uint16(p:Packet, val:UInt16):Int {
	if (p.pos > p.maxlen - 2)
		return 0;
	Pointer.fromRaw(p.data).setAt(p.pos, (val) & 0xFF);
	Pointer.fromRaw(p.data).setAt(p.pos + 1, (val >> 8) & 0xFF);
	p.pos += 2;
	return 1;
}

function write_chars(p:Packet, str:RawPointer<UInt8>, nb_chars:Int) {
	var i = 0;
	if (p.pos > p.maxlen - nb_chars)
		return 0;
	for (i in 0...nb_chars)
		Pointer.fromRaw(p.data).setAt(p.pos++, str[i]);
	return 1;
}

function read_uint32(p:ROPacket, val:UInt32) {
	if (p.pos > p.maxlen - 4)
		return 0;

	val = cast Pointer.fromRaw(p.data).at(p.pos);
	val |= cast(Pointer.fromRaw(p.data).at(p.pos + 1) << 8);
	val |= cast(Pointer.fromRaw(p.data).at(p.pos + 2) << 16);
	val |= cast(Pointer.fromRaw(p.data).at(p.pos + 3) << 24);
	p.pos += 4;
	return 1;
}

function read_uint16(p:ROPacket, val:UInt16) {
	if (p.pos > p.maxlen - 4)
		return 0;
	val = cast Pointer.fromRaw(p.data).at(p.pos);
	val |= cast(Pointer.fromRaw(p.data).at(p.pos + 1) << 8);
	p.pos += 2;
	return 1;
}

function read_chars(p:Packet, str:RawPointer<UInt8>, nb_chars:Int) {
	var i = 0;
	if (p.pos > p.maxlen - nb_chars)
		return 0;
	for (i in 0...nb_chars) {
		str[i] = Pointer.fromRaw(p.data).at(p.pos++);
	}
	return 1;
}

class OpusHeader {
	public var version:Int = 0;
	public var channels:Int = 0;
	public var preskip:Int = 0;
	public var input_sample_rate:UInt32 = 0;
	public var gain:Int = 0;
	public var channel_mapping:Int = 0;
	public var nb_streams:Int = 0;
	public var nb_coupled:Int = 0;
	public var stream_map:Array<cpp.UInt8> = [];

	public function new() {}

	public function parse(packet:RawPointer<cpp.UInt8>, len:Int) {
		var i = 0;
		var str:Array<UInt8> = [];
		var p:ROPacket = {};
		var ch:cpp.UInt8 = 0;
		var shortval:Int16 = 0;

		p.data = packet;
		p.maxlen = len;
		p.pos = 0;
		str[8] = 0;

		if (len < 19)
			return 0;

		read_chars(p, Pointer.ofArray(str).get_raw(), 8);
		if (!Bytes.ofData(str).toString().contains("OpusHead"))
			return 0;

		if (read_chars(p, RawPointer.addressOf(ch), 1) == 0)
			return 0;

		this.version = ch;

		if ((this.version & 240) != 0)
			/* Only major version 0 supported. */
			return 0;

		if (read_chars(p, RawPointer.addressOf(ch), 1) == 0)
			return 0;

		if (read_uint16(p, shortval) == 0)
			return 0;

		this.preskip = shortval;

		if (read_uint32(p, this.input_sample_rate) == 0)
			return 0;

		if (read_uint16(p, shortval) == 0)
			return 0;

		this.gain = shortval;

		if (read_chars(p, RawPointer.addressOf(ch), 1) == 0)
			return 0;

		this.channel_mapping = ch;

		if (this.channel_mapping != 0) {
			if (read_chars(p, RawPointer.addressOf(ch), 1) == 0)
				return 0;

			if (ch < 1)
				return 0;

			this.nb_streams = ch;

			if (read_chars(p, RawPointer.addressOf(ch), 1) == 0)
				return 0;

			if (ch > this.nb_streams || (ch + this.nb_streams) > 255)
				return 0;

			this.nb_coupled = ch;

			/* Multi-stream support */
			for (i in 0...this.channels) {
				if (read_chars(p, RawPointer.addressOf(this.stream_map[i]), 1) == 0)
					return 0;
				if (this.stream_map[i] > (this.nb_streams + this.nb_coupled) && this.stream_map[i] != 255)
					return 0;
			}
		} else {
			if (this.channels > 2)
				return 0;
			this.nb_streams = 1;
			this.nb_coupled = this.channels > 1 ? 1 : 0;
			this.stream_map[0] = 0;
			this.stream_map[1] = 1;
		}

		/*For version 0/1 we know there won't be any more data
			so reject any that have data past the end. */
		if ((this.version == 0 || this.version == 1) && p.pos != len)
			return 0;

		return 1;
	}

	public function to_packet(packet:RawPointer<UInt8>, len:Int):Int {
		var i = 0;
		var p:Packet = {};
		var ch:cpp.UInt8 = 0;

		p.data = packet;
		p.maxlen = len;
		p.pos = 0;

        var str:Array<UInt8> = Bytes.ofString("OpusHead").getData();

		if (len < 19)
			return 0;
		if (write_chars(p, Pointer.ofArray(str).get_raw(), 8) == 0)
			return 0;
		/* Version is 1 */
		ch = 1;
		if (write_chars(p, RawPointer.addressOf(ch), 1) == 0)
			return 0;

		ch = this.channels;
		if (write_chars(p, RawPointer.addressOf(ch), 1) == 0)
			return 0;

		if (write_uint16(p, this.preskip) == 0 )
			return 0;

		if (write_uint32(p, this.input_sample_rate) == 0)
		    return 0;

		if (write_uint16(p, this.gain) == 0)
			return 0;

		ch = this.channel_mapping;
		if (write_chars(p, RawPointer.addressOf(ch), 1) == 0)
			return 0;

		if (this.channel_mapping != 0) {
			ch = this.nb_streams;
			if (write_chars(p, RawPointer.addressOf(ch), 1) == 0)
				return 0;

			ch = this.nb_coupled;
			if (write_chars(p, RawPointer.addressOf(ch), 1) == 0)
				return 0;

			/* Multi-stream support */
			for (i in 0...this.channels)
			{
				if (write_chars(p, RawPointer.addressOf(this.stream_map[i]), 1) == 0)
					return 0;
			}
		}

		return p.pos;
	}
}
