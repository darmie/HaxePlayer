package demuxer;

import cpp.SizeT;
import cpp.UInt64;
import haxe.io.Bytes;
import cpp.UInt32;
import cpp.Char;
import cpp.Callable;
import cpp.RawPointer;
import cpp.UInt8;
import oggz.Oggz;
import cpp.Int64;
import oggz.Oggz.OggzStreamContent;
import skeleton.Skeleton.OggSkeleton;
import cpp.Pointer;
import nestegg.Nestegg;
import nestegg.Nestegg.NESTEGG_TRACK;
import nestegg.Nestegg.VideoParams;

// Copyright (c) 2013-2019 Brion Vibber and other contributors
// Copyright (c) 2021 Damilare Akinlaja
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

var demuxContext:Pointer<Nestegg> = null;
var bufferQueue:BufferQueue;
var packet:oggz.Oggz.Packet;
var oggz:cpp.RawPointer<Oggz>;
var hasVideo:Bool = false;
var videoCodec:Int = -1;
var videoTrack:UInt8 = 0;
var videoCodecName:String = null;
var hasAudio:Bool = false;
var audioCodec:Int = -1;
var audioTrack:UInt8 = 0;
var audioCodecName:String = null;
var seekTime:Int64;
var seekTrack:UInt8;
var startPosition:Int64;
var nestegg:Pointer<Nestegg>;
var lastKeyframeKimestamp:Float = -1;
var appState:AppState;
var callback_audio_packet:(buffer:Bytes, len:Int, audioTimestamp:Float, discardPadding:Float) -> Void;

var callback_init_video:(frameWidth:Int, frameHeight:Int, chromaWidth:Int, chromaHeight:Int, fps:Float, picWidth:Int, picHeight:Int, picX:Int, picY:Int,
	displayWidth:Int, displayHeight:Int) -> Void;

var callback_video_packet:(buffer:Bytes, len:Int, frameTimestamp:Float, keyframeTimestamp:Float, isKeyframe:Bool) -> Void;
var callback_loaded_metadata:(videoCodec:String, audioCodec:String) -> Void;
var callback_seek:(offset:Int64) -> Void;

function demuxer_init() {
	appState = STATE_BEGIN;
	bufferQueue = new BufferQueue();
}

function logCallback(context:Nestegg, severity:NestEggLog, message:String) {
	switch severity {
		case NESTEGG_LOG_INFO:
			{
				Sys.println(message);
			}
		case _:
	}
}

function readCallback(buffer:RawPointer<cpp.Void>, length:Int, userdata:RawPointer<cpp.Void>):Int {
	var bq:RawPointer<BufferQueue> = Pointer.fromRaw(userdata).rawCast();
	if (Pointer.fromRaw(bq).ref.headroom() < haxe.Int64.ofInt(length)) {
		// End of stream. Demuxer can recover from this if more data comes in!
		return 0;
	}
	if (Pointer.fromRaw(bq).ref.read(Pointer.fromRaw(buffer).rawCast(), length) < length) {
		// error
		return -1;
	}

	// success
	return 1;
}

function seekCallback(offset:Int64, whence:Seek, userdata:RawPointer<cpp.Void>):Int {
	var pos:Int64 = 0;

	var bq:RawPointer<BufferQueue> = Pointer.fromRaw(userdata).rawCast();

	switch (whence) {
		case SEEK_SET:
			pos = offset;
		case SEEK_CUR:
			pos = Pointer.fromRaw(bq).ref.pos + offset;
		case SEEK_END: // not implemented
		default:
			return -1;
	}
	if (Pointer.fromRaw(bq).ref.seek(pos) == -1) {
		// printf("Buffer seek failure in webm demuxer\n");
		return -1;
	}
	return 0;
}

function tellCallback(user_handle:RawPointer<cpp.Void>):Int64 {
	var bq:RawPointer<BufferQueue> = Pointer.fromRaw(user_handle).rawCast();
	return Pointer.fromRaw(bq).ref.tell();
}

var io_callbacks:IO = IO.init(Callable.fromStaticFunction(readCallback), Callable.fromStaticFunction(seekCallback), Callable.fromStaticFunction(tellCallback));

/**
 * Safe read of EBML id or data size int64 from a data stream.
 * 
 * @param bufferQueue 
 * @param val 
 * @param keep_mask_bit 
 * 
 * @returns byte count of the ebml number on success, or 0 on failure
 */
function read_ebml_int64(bufferQueue:BufferQueue, val:Int64, keep_mask_bit:Int):Int {
	// Count of initial 0 bits plus first 1 bit encode total number of bytes.
	// Rest of the bits are a big-endian number.
	var first:UInt8 = 0;
	if (bufferQueue.read(RawPointer.addressOf(first), 1) == -1) {
		// printf("out of bytes at start of field\n");
		return 0;
	}
	if (first == 0) {
		// printf("zero field\n");
		return 0;
	}

	var shift = 0;

	while ((first & 0x80) == 0) {
		shift++;
		first = first << 1;
	}

	var byteCount = shift + 1;
	if (keep_mask_bit == 0) {
		// id keeps the mask bit, data size strips it
		first = first & 0x7f;
	}

	// Save the top bits from that first byte.
	val = first >> shift;

	for (_ in 1...byteCount) {
		var next:UInt8 = 0;
		if (bufferQueue.read(RawPointer.addressOf(next), 1) == -1) {
			// printf("out of bytes in field\n");
			return 0;
		}
		val = val << 8 | next;
	}

	// printf("byteCount %d; val %lld\n", byteCount, *val);
	return byteCount;
}

function readyForNextPacket() {
	var pos = bufferQueue.tell();
	var ok:Bool = false;
	var id:Int64, size:Int64 = 0;
	var idSize:Int, sizeSize:Int = 0;

	idSize = read_ebml_int64(bufferQueue, id, 1);

	if (idSize > 0) {
		if (id != untyped __cpp__("0x1c53bb6bLL")) {
			// Right now we only care about reading the cues.
			// If used elsewhere, unpack that. ;)
			ok = true;
		}
		sizeSize = read_ebml_int64(bufferQueue, size, 0);
		if (sizeSize > 0) {
			// printf("packet is %llx, size is %lld, headroom %lld\n", id, size, bq_headroom(bufferQueue));
			if (bufferQueue.headroom() >= size) {
				ok = true;
			}
		}
	}

	/*
		if (!ok) {
			printf("not ready for packet! %lld/%lld %d %d %llx %lld\n", bq_tell(bufferQueue), bq_headroom(bufferQueue), idSize, sizeSize, id, size);
		} else {
			printf("ready for packet! %lld/%lld %d %d %llx %lld\n", bq_tell(bufferQueue), bq_headroom(bufferQueue), idSize, sizeSize, id, size);
		}
	 */
	bufferQueue.seek(pos);
	return ok;
}

function processBegin() {
	// This will read through headers, hopefully we have enough data
	// or else it may fail and explode.
	io_callbacks.userdata = Pointer.addressOf(bufferQueue).rawCast();
	if (Nestegg.initCallback(demuxContext, io_callbacks, bufferQueue.headroom()) < 0) {
		// Seek back to start so it can retry when more data is available.
		bufferQueue.seek(0);
		return 0;
	}

	// The first cluster starts a few bytes back, since we've already
	// peeked-ahead its type and size.
	startPosition = bufferQueue.tell() - 12;

	// Look through the tracks finding our video and audio
	var tracks:UInt32 = 0;
	if (!demuxContext.ref.track_count(Pointer.addressOf(tracks))) {
		tracks = 0;
	}

	for (track in 0...tracks) {
		var trackType = demuxContext.ref.track_type(track);
		var codec = demuxContext.ref.track_codec_id(track);

		if (trackType == VIDEO && !hasVideo) {
			if (codec == VP8) {
				hasVideo = true;
				videoTrack = track;
				videoCodec = codec;
				videoCodecName = "vp8";
			}
			if (codec == VP9) {
				hasVideo = true;
				videoTrack = track;
				videoCodec = codec;
				videoCodecName = "vp9";
			}
			if (codec == AV1) {
				hasVideo = true;
				videoTrack = track;
				videoCodec = codec;
				videoCodecName = "av1";
			}
		}

		if (trackType == AUDIO && !hasAudio) {
			if (codec == VORBIS) {
				hasAudio = true;
				audioTrack = track;
				audioCodec = codec;
				audioCodecName = "vorbis";
			}
			if (codec == OPUS) {
				hasAudio = true;
				audioTrack = track;
				audioCodec = codec;
				audioCodecName = "opus";
			}
		}
	}

	if (hasVideo) {
		var videoParams:VideoParams = VideoParams.init();
		if (!demuxContext.ref.track_video_params(videoTrack, Pointer.addressOf(videoParams))) {
			// failed! something is wrong...
			hasVideo = false;
		} else {
			callback_init_video(videoParams.width, videoParams.height, videoParams.width >> 1, videoParams.height >> 1, // @todo assuming 4:2:0
				0, // @todo get fps
				videoParams.width
				- videoParams.crop_left
				- videoParams.crop_right,
				videoParams.height
				- videoParams.crop_top
				- videoParams.crop_bottom, videoParams.crop_left, videoParams.crop_top, videoParams.display_width,
				videoParams.display_height);
		}
	}

	if (hasAudio) {
		var audioParams:AudioParams = AudioParams.init();
		if (!demuxContext.ref.track_audio_params(videoTrack, Pointer.addressOf(audioParams))) {
			// failed! something is wrong...
			hasVideo = false;
		} else {
			var codecDataCount:UInt32 = 0;

			demuxContext.ref.track_codec_data_count(audioTrack, Pointer.addressOf(codecDataCount));

			for (i in 0...codecDataCount) {
				var data:Array<UInt8> = [];
				var len:Int = 0;
				var ret = demuxContext.ref.track_codec_data(audioTrack, i, Pointer.ofArray(data).raw, Pointer.addressOf(len));
				if (!ret) {
					throw 'failed to read codec data ${i}\n';
				}
				// ... store these!
				if (callback_init_video != null) {
					callback_audio_packet(Bytes.ofData(data), len, -1, 0.0);
				}
			}
		}
	}

	appState = STATE_DECODING;
	callback_loaded_metadata(videoCodecName, audioCodecName);

	return 1;
}

function processDecoding() {
	// printf("webm processDecoding: reading next packet...\n");

	// Do the nestegg_read_packet dance until it fails to read more data,
	// at which point we ask for more. Hope it doesn't explode.

	var packet = Packet.init();
	var ret = demuxContext.ref.read_packet(packet);
	if (ret == 0) {
		// End of stream? Usually means we need more data.
		demuxContext.ref.read_reset();
		return 0;
	} else if (ret < 0) {
		// Unknown unrecoverable error
		Sys.println('webm processDecoding: error ${ret}');
		return 0;
	} else {
		// printf("webm processDecoding: got packet?\n");
		var track:UInt32 = 0;
		packet.ref.track(Pointer.addressOf(track));
		var timestamp_ns:UInt64 = 0;
		packet.ref.tstamp(Pointer.addressOf(timestamp_ns));
		var timestamp = timestamp_ns / 1000000000.0;

		var data:Array<UInt8> = [];
		var data_len:SizeT = 0;
		packet.ref.data(0, Pointer.addressOf(data), Pointer.addressOf(data_len));

		if (hasVideo && track == videoTrack) {
			var isKeyframe = packet.ref.has_keyframe() == NESTEGG_PACKET_HAS_KEYFRAME.TRUE;
			if (isKeyframe) {
				lastKeyframeKimestamp = timestamp;
			}
			callback_video_packet(Bytes.ofData(data), data_len, timestamp, lastKeyframeKimestamp, isKeyframe);
		} else if (hasAudio && track == audioTrack) {
			var discard_padding:Int64 = 0;
			packet.ref.discard_padding(Pointer.addressOf(discard_padding));
			callback_audio_packet(Bytes.ofData(data), data_len, timestamp, discard_padding);
		} else {
			// throw away unknown packets
		}
		packet.ref.free();
		return 1;
	}

	return 0;
}

function processSeeking() {
	bufferQueue.lastSeekTarget = -1;
	var r:Bool = false;
	if (demuxContext.ref.has_cues()) {
		r = demuxContext.ref.track_seek(seekTrack, seekTime);
	} else {
		// Audio WebM files often do not contain cues.
		// Seek back to the start of the file, then demux from there.
		// high-level code will do a linear search to the target.
		r = demuxContext.ref.offset_seek(startPosition);
	}

	if (r) {
		if (bufferQueue.lastSeekTarget == -1) {
			// Maybe we just need more data?
			// printf("is seeking processing... FAILED at %lld %lld %lld\n", bufferQueue->pos, bq_start(bufferQueue), bq_end(bufferQueue));
		} else {
			// We need to go off and load stuff...
			// printf("is seeking processing... MOAR SEEK %lld %lld %lld\n", bufferQueue->lastSeekTarget, bq_start(bufferQueue), bq_end(bufferQueue));
			var target = bufferQueue.lastSeekTarget;
			bufferQueue.flush();
			bufferQueue.pos = target;
			callback_seek(target);
		}
		// Return false to indicate we need i/o
		return 0;
	} else {
		appState = STATE_DECODING;
		// Roll over to packet processing.
		// Return true to indicate we should keep reading.
		return 1;
	}
}

function demuxer_receive_input(buffer:Bytes, bufSize:Int) {
	if (bufSize > 0) {
		bufferQueue.append(buffer, bufSize);
	}
}


function demuxer_process() {
    if (appState == STATE_BEGIN) {
        return processBegin();
    } else if (appState == STATE_DECODING) {
        return processDecoding();
    } else if (appState == STATE_SEEKING) {
        if (readyForNextPacket()) {
            return processSeeking();
        } else {
            // need more data
            //printf("not ready to read the cues\n");
            return 0;
        }
	} else {
		// uhhh...
		//printf("Invalid appState in ogv_demuxer_process\n");
        return 0;
	}
}

function demuxer_destroy() {
    // should probably tear stuff down, eh
    bufferQueue.free();
    bufferQueue = null;
}

function demuxer_flush() {
    bufferQueue.flush();
    // we may not need to handle the packet queue because this only
    // happens after seeking and nestegg handles that internally
    lastKeyframeKimestamp = -1;
}

/**
 *  @return segment length in bytes, or -1 if unknown
 */
function demuxer_media_length() {
    // @todo check if this is needed? maybe an ogg-specific thing
	return -1;
}

/**
 * 
 * @return segment duration in seconds, or -1 if unknown
 */
function demuxer_media_duration():Float {
    var duration_ns:UInt64 = 0;
    if (!demuxContext.ref.duration(Pointer.addressOf(duration_ns))) {
    	return -1;
    } else {
	    return duration_ns / 1000000000.0;
	}
}

function demuxer_seekable():Int {
   // Audio WebM files often have no cues; allow brute-force seeking
  // by linear demuxing through hopefully-cached data.
	return 1; 
}

function demuxer_keypoint_offset(time_ms:Int64) {
    // can't do with nestegg's API; use ogv_demuxer_seek_to_keypoint instead
	return -1;
}

function demuxer_seek_to_keypoint(time_ms:Int64) {
    appState = STATE_SEEKING;
    seekTime = time_ms * untyped __cpp__("1000000LL");
    if (hasVideo) {
        seekTrack = videoTrack;
    } else if (hasAudio) {
        seekTrack = audioTrack;
    } else {
        return 0;
    }
    processSeeking();
    return 1;
}