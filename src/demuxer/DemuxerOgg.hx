package demuxer;

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
import cpp.Int32;
import haxe.io.BytesOutput;
import haxe.io.Bytes;
import cpp.Callable;
import cpp.RawPointer;
import cpp.Pointer;
import cpp.Int64;
import haxe.Int64Helper;
import oggz.Oggz;
import skeleton.Skeleton;
import skeleton.Skeleton.OggSkeleton;
import nestegg.Nestegg;
import demuxer.NestEggLog;

final OGGZ_ERR_STOP_OK = -14;
var bufferQueue:BufferQueue;
var packet:oggz.Oggz.Packet;
var oggz:cpp.RawPointer<Oggz>;
var hasVideo:Bool = false;
var videoStream:Int64;
var videoCodec:OggzStreamContent;
var videoHeaderComplete:Int;
var videoCodecName:String = null;
var hasAudio:Bool = false;
var audioStream:Int64;
var audioCodec:OggzStreamContent;
var audioHeaderComplete:Int;
var audioCodecName:String = null;
var hasSkeleton:Bool = false;
var skeletonStream:Int64;
var skeleton:Pointer<OggSkeleton>;
var skeletonHeadersComplete:Bool;
var appState:AppState;
var callback_loaded_metadata:(videoCodec:String, audioCodec:String) -> Void;
var callback_video_packet:(buffer:cpp.RawPointer<cpp.UInt8>, len:Int, frameTimeStamp:Float, keyframeTimestamp:Float, isKeyframe:Bool) -> Void;
var callback_audio_packet:(buffer:cpp.RawPointer<cpp.UInt8>, len:Int, audioTimeStamp:Float, discardPadding:Float) -> Void;

function readPacketCallback(oggz:RawPointer<Oggz>, packet:RawPointer<oggz.Oggz.Packet>, serialno:Long, userdata:RawPointer<cpp.Void>):Int {
	switch (appState) {
		case STATE_BEGIN:
			return processBegin(Pointer.fromRaw(packet).ref, serialno);
		case STATE_SKELETON:
			return processSkeleton(Pointer.fromRaw(packet).ref, serialno);
		case STATE_DECODING:
			return processDecoding(Pointer.fromRaw(packet).ref, serialno);
		default:
			// printf("Invalid state in Ogg readPacketCallback");
			return OGGZ_STOP_ERR;
	}
}

function readCallback(userHandle:RawPointer<cpp.Void>, buf:RawPointer<cpp.Void>, n:cpp.SizeT):cpp.SizeT {
	var bq:RawPointer<BufferQueue> = Pointer.fromRaw(userHandle).rawCast();
	var available = Pointer.fromRaw(bq).ref.headroom();
	var to_read:Int64 = 0;
	if (n < available) {
		to_read = n;
	} else {
		to_read = available;
	}

	var ret = Pointer.fromRaw(bq).ref.read(Pointer.fromRaw(buf).rawCast(), to_read);
	if (ret < 0) {
		return -1;
	} else {
		return to_read;
	}
}

function seekCallback(user_handle:RawPointer<cpp.Void>, offset:Int64, whence:Int):Int {
	var bq:RawPointer<BufferQueue> = Pointer.fromRaw(user_handle).rawCast();
	var pos:Int64 = 0;
	switch cast(whence, Seek) {
		case SEEK_SET:
			pos = offset;
		case SEEK_CUR:
			pos = Pointer.fromRaw(bq).ref.tell() + offset;
		case SEEK_END: // not implemented
		default:
			return -1;
	}

	if (Pointer.fromRaw(bq).ref.seek(pos) == -1) {
		// printf("Buffer seek failure in ogg demuxer; %lld (%ld %d)\n", pos, offset, whence);
		return -1;
	}
	return pos;
}

function tellCallback(user_handle:RawPointer<cpp.Void>):Int64 {
	var bq:RawPointer<BufferQueue> = Pointer.fromRaw(user_handle).rawCast();
	return Pointer.fromRaw(bq).ref.tell();
}

function demuxer_init() {
	appState = STATE_BEGIN;
	bufferQueue = new BufferQueue();
	oggz = Oggz.init(OGGZ_READ | OGGZ_AUTO);
	Oggz.set_read_callback(oggz, -1, Callable.fromStaticFunction(readPacketCallback), null);
	Oggz.io_set_read(oggz, Callable.fromStaticFunction(readCallback), Pointer.addressOf(bufferQueue).rawCast());
	Oggz.io_set_seek(oggz, Callable.fromStaticFunction(seekCallback), Pointer.addressOf(bufferQueue).rawCast());
	Oggz.io_set_tell(oggz, Callable.fromStaticFunction(tellCallback), bufferQueue);

	skeleton = Skeleton.init();
}

function demuxer_receive_input(buffer:Bytes, bufSize:Int) {
	bufferQueue.append(buffer, bufSize);
}

function demuxer_process() {
	do {
		// read at most this many bytes in one go
		// should be enough to resync ogg stream
		var headroom = bufferQueue.headroom();
		var bufsize:Int64 = 65536;

		if (headroom < bufsize) {
			bufsize = headroom;
		}

		var ret = Oggz.read(oggz, bufsize);

		// printf("demuxer returned %d on %d bytes\n", ret, bufsize);
		if (ret == OGGZ_ERR_STOP_OK) {
			// We got a packet!
			return 1;
		} else if (haxe.Int64.toInt(ret) > 0) {
			// We read some data, but no packets yet.
			// printf("read %d bytes\n", ret);
			continue;
		} else if (ret == 0) {
			// printf("EOF %d from oggz_read\n", ret);
			return 0;
		} else if (haxe.Int64.toInt(ret) < 0) {
			// printf("Error %d from oggz_read\n", ret);
			return 0;
		}
	} while (true);

	return 0;
}

function demuxer_destroy() {
	Skeleton.destroy(skeleton);
	Oggz.close(oggz);
	bufferQueue.free();
	bufferQueue = null;
}

function demuxer_media_length() {
	var segment_len:Int64 = -1;
	if (skeletonHeadersComplete) {
		Skeleton.get_segment_len(skeleton, RawPointer.addressOf(segment_len));
	}

	return segment_len;
}

function demuxer_media_duration():Float {
    if (skeletonHeadersComplete) {
        var ver_maj:Int64 = -1, ver_min:Int64 = -1;
        Skeleton.get_ver_maj(skeleton, RawPointer.addressOf(ver_maj));
        Skeleton.get_ver_min(skeleton, RawPointer.addressOf(ver_min));

        var serial_nos:Array<Int32> = [];
        var  nstreams = 0;

        if (videoStream >= haxe.Int64.ofInt(0)) {
            serial_nos[nstreams++] = haxe.Int64.toInt(videoStream);
        }
        if (audioStream >= haxe.Int64.ofInt(0)) {
            serial_nos[nstreams++] = audioStream;
        }

        var firstSample:Float = -1;
        var lastSample:Float = -1;
        for (i in 0...nstreams){
            var first_sample_num:Int64 = -1,
                        first_sample_denum:Int64 = -1,
                        last_sample_num:Int64 = -1,
                        last_sample_denum:Int64 = -1;

            Skeleton.get_first_sample_num(skeleton, RawPointer.addressOf(serial_nos[i]), RawPointer.addressOf(first_sample_num));
            Skeleton.get_first_sample_denum(skeleton, RawPointer.addressOf(serial_nos[i]), RawPointer.addressOf(first_sample_denum));

            Skeleton.get_last_sample_num(skeleton, RawPointer.addressOf(serial_nos[i]), RawPointer.addressOf(last_sample_num));
            Skeleton.get_last_sample_denum(skeleton, RawPointer.addressOf(serial_nos[i]), RawPointer.addressOf(last_sample_denum));

            var firstStreamSample = first_sample_num / first_sample_denum;
            if (firstSample == -1 || firstStreamSample < firstSample) {
                firstSample = firstStreamSample;
            }

            var lastStreamSample = last_sample_num / last_sample_denum;
            if (lastSample == -1 || lastStreamSample > lastSample) {
                lastSample = lastStreamSample;
            }
        }

        return lastSample - firstSample;

    }

    return -1;
}

function demuxer_seekable():Int {
    // even if we don't have the skeleton tracks, we allow bisection
    return 1;
}

function demuxer_keypoint_offset(time_ms:Int64){
    var offset:Int64 = -1;
    if (skeletonHeadersComplete) {
        var serial_nos:Array<Int32> = [];
        var nstreams = 0;
        if (hasVideo) {
            serial_nos[nstreams++] = videoStream;
        } else if (hasAudio) {
			serial_nos[nstreams++] = audioStream;
		}
        Skeleton.get_keypoint_offset(skeleton, Pointer.ofArray(serial_nos).raw, nstreams, time_ms, RawPointer.addressOf(offset));
    }
    return offset;
}

function demuxer_seek_to_keypoint() {
    return 0;
}

function demuxer_flush() {
    Oggz.purge(oggz);

    // Need to "seek" to clear out stored units
    var ret = Oggz.seek(oggz, 0, Seek.SEEK_CUR);
	if (ret < haxe.Int64.ofInt(0)) {
		//printf("Failed to 'seek' oggz %d\n", ret);
	}

    bufferQueue.flush();

}



function processSkeleton(packet:oggz.Oggz.Packet, serialno:Int64):Int {
	var timestamp = Oggz.tell_units(oggz) / 1000.0;
	var keyframeTimestamp = calc_keyframe_timestamp(packet, serialno);
	if (hasSkeleton && skeletonStream == serialno) {
		var ret = Skeleton.decode_header(skeleton, Pointer.addressOf(packet.op));
		if (ret < 0) {
			// printf("Error processing skeleton packet: %d\n", ret);
			return OGGZ_STOP_ERR;
		}
		if (packet.op.e_o_s >= haxe.Int64.ofInt(1)) {
			skeletonHeadersComplete = true;
			appState = STATE_DECODING;
			callback_loaded_metadata(videoCodecName, audioCodecName);
		}

		if (hasVideo && serialno == videoStream) {
			callback_video_packet(packet.op.packet, packet.op.bytes, timestamp, keyframeTimestamp, is_keyframe_theora(packet));
		}

		if (hasAudio && serialno == audioStream) {
			callback_audio_packet(packet.op.packet, packet.op.bytes, timestamp, 0.0);
		}
	}
	return OGGZ_CONTINUE;
}

function processDecoding(packet:oggz.Oggz.Packet, serialno:Int64):Int {
	var timestamp = Oggz.tell_units(oggz) / 1000.0;
	var keyframeTimestamp = calc_keyframe_timestamp(packet, serialno);

	if (hasVideo && serialno == videoStream) {
		if (packet.op.bytes > haxe.Int64.ofInt(0)) {
			// Skip 0-byte Theora packets, they're dupe frames.
			callback_video_packet(packet.op.packet, packet.op.bytes, timestamp, keyframeTimestamp, is_keyframe_theora(packet));
			return OGGZ_STOP_OK;
		}
	}

    if (hasAudio && serialno == audioStream) {
    	callback_audio_packet(packet.op.packet, packet.op.bytes, timestamp, 0.0);
		return OGGZ_STOP_OK;
    }

	return OGGZ_CONTINUE;
}

function processBegin(packet:oggz.Oggz.Packet, serialno:Int64):Int {
	var bos = (packet.op.b_o_s != 0);

	if (!bos) {
		// Not a bitstream start -- move on to header decoding...
		if (hasSkeleton) {
			appState = STATE_SKELETON;
			return processSkeleton(packet, serialno);
		} else {
			appState = STATE_DECODING;
			callback_loaded_metadata(videoCodecName, audioCodecName);
			return processDecoding(packet, serialno);
		}
	}

	var content = Oggz.stream_get_content(oggz, serialno);

	if (!hasVideo && content == OGGZ_CONTENT_THEORA) {
		hasVideo = true;
		videoCodec = content;
		videoCodecName = "theora";
		videoStream = serialno;
		callback_video_packet(packet.op.packet, packet.op.bytes, -1, -1, false);
		return OGGZ_CONTINUE;
	}

	if (!hasAudio && content == OGGZ_CONTENT_VORBIS) {
		hasAudio = true;
		audioCodec = content;
		audioCodecName = "vorbis";
		audioStream = serialno;
		callback_audio_packet(packet.op.packet, packet.op.bytes, -1, 0.0);
		return OGGZ_CONTINUE;
	}

	if (!hasAudio && content == OGGZ_CONTENT_OPUS) {
		hasAudio = true;
		audioCodec = content;
		audioCodecName = "opus";
		audioStream = serialno;
		callback_audio_packet(packet.op.packet, packet.op.bytes, -1, 0.0);
		return OGGZ_CONTINUE;
	}

	if (!hasSkeleton && content == OGGZ_CONTENT_SKELETON) {
		hasSkeleton = true;
		skeletonStream = serialno;

		var ret = Skeleton.decode_header(skeleton, Pointer.addressOf(packet.op));
		if (ret == 0) {
			skeletonHeadersComplete = true;
		} else if (ret > 0) {
			// Just keep going
		} else {
			// printf("Invalid ogg skeleton track data? %d\n", ret);
			return OGGZ_STOP_ERR;
		}
	}

	return OGGZ_CONTINUE;
}

function is_keyframe_theora(packet:oggz.Oggz.Packet):Bool {
	var granulepos = Oggz.tell_granulepos(oggz);
	var granuleshift = Oggz.get_granuleshift(oggz, videoStream);
	var key_frameno = (granulepos >> granuleshift);
	return (granulepos == (key_frameno << granuleshift));
}

function calc_keyframe_timestamp(packet:oggz.Oggz.Packet, serialno:Int64):Float {
	var granulepos = Oggz.tell_granulepos(oggz);
	var granuleshift = Oggz.get_granuleshift(oggz, serialno);
	var granulerate_n:Int64 = 0;
	var granulerate_d:Int64 = 0;

	Oggz.get_granulerate(oggz, serialno, RawPointer.addressOf(granulerate_n), RawPointer.addressOf(granulerate_d));

	return (granulepos >> granuleshift) * granulerate_d / granulerate_n;
}
