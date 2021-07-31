import opus.Opus;
import opus.Opus.OPUS_OK;
import opus.Opus.OPUS_UNIMPLEMENTED;
import opus.Opus.OpusMultistream;
import cpp.Pointer;
import cpp.Reference;
import cpp.RawPointer;
import ogg.OggPage.OggPacket;
import opus.Opus.OpusMSDecoder;

function opus_process_header(op:RawPointer<OggPacket>, mapping_family:Reference<Int>, channels:Reference<Int>, preskip:Reference<Int>, gain:Reference<Float>, streams:Reference<Int>):Pointer<OpusMSDecoder> {
	var err = 0;

	var header:OpusHeader = new OpusHeader();

	if (header.parse(Pointer.fromRaw(op).ref.packet, Pointer.fromRaw(op).ref.bytes) == 0) {
		return null;
	}

	Pointer.addressOf(mapping_family).ref = header.channel_mapping;
	Pointer.addressOf(channels).ref = header.channels;

	Pointer.addressOf(preskip).ref = header.preskip;

	final st = OpusMultistream.decoder_create(48000, header.channels, header.nb_streams, header.nb_coupled, Pointer.ofArray(header.stream_map).raw,
		Pointer.addressOf(err).raw);

	if (err != OPUS_OK) {
		// fprintf(stderr, "Cannot create encoder: %s\n", opus_strerror(err));
		return null;
	}
	if (st == null) {
		// fprintf (stderr, "Decoder initialization failed: %s\n", opus_strerror(err));
		return null;
	}

	Pointer.addressOf(streams).ref = header.nb_streams;

	if (header.gain != 0) {
		/*Gain API added in a newer libopus version, if we don't have it
			we apply the gain ourselves. We also add in a user provided
			manual gain at the same time. */     
		err = OpusMultistream.decoder_ctl(st, untyped __cpp__("OPUS_SET_GAIN({0})", header.gain));
		if (err == OPUS_UNIMPLEMENTED) {
			Pointer.addressOf(gain).set_ref(Math.pow(10., header.gain / 5120.));
		} else if (err != OPUS_OK) {
			// fprintf (stderr, "Error setting gain: %s\n", opus_strerror(err));
			return null;
		}
	}

	return st;
}
