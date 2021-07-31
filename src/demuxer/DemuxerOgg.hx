package demuxer;

import cpp.Pointer;
import cpp.Int64;
import haxe.Int64Helper;
import oggz.Oggz;
import skeleton.Skeleton;
import skeleton.Skeleton.OggSkeleton;
import nestegg.Nestegg;
import demuxer.NestEggLog;


class DemuxerOgg {
    var bufferQueue:BufferQueue;
    var packet:oggz.Oggz.Packet;
    var oggz:cpp.RawPointer<Oggz>;

    var hasVideo:Bool;
    var videoStream:Float;
    var videoCodec:OggzStreamContent;
    var videoHeaderComplete:Int;
    var videoCodecName:String;


    var hasAudio:Bool;
    var audioStream:Float;
    var audioCodec:OggzStreamContent;
    var audioHeaderComplete:Int;
    var audioCodecName:String;

    var hasSkeleton:Bool;
    var skeletonStream:Float;
    var skeleton:OggSkeleton;
    var skeletonHeadersComplete:Int;

    var appState:AppState;

    public var callback_loaded_metadata:(videoCodec:String, audioCodec:String)->Void;
    public var callback_video_packet:(buffer:cpp.RawPointer<cpp.UInt8>, len:Int, frameTimeStamp:Float, keyframeTimestamp:Int, isKeyframe:Int)->Void;
    public var callback_audio_packet:(buffer:cpp.RawPointer<cpp.UInt8>, len:Int, audioTimeStamp:Float, discardPadding:Float)->Void;

    public function new() {
        appState = STATE_BEGIN;
        bufferQueue = new BufferQueue();
    }

    // public static function logCallback(context:Nestegg, severity:NestEggLog, message:String) {
    //     switch severity {
    //         case NESTEGG_LOG_INFO:{
    //             Sys.println(message);
    //         }
    //         case _:
    //     }
    // }

    public function processSkeleton(serialno:Int64):Int {
        return 0;
    }

    public  function processDecoding(serialno:Int64):Int {
        return 0;
    }

    public function processBegin(serialno:Int64):Int {
        var bos = (packet.op.b_o_s != 0);

        if (!bos) {
            // Not a bitstream start -- move on to header decoding...
            if (hasSkeleton) {
                appState = STATE_SKELETON;
                return processSkeleton(serialno);
            } else {
                appState = STATE_DECODING;
                callback_loaded_metadata(videoCodecName, audioCodecName);
                return processDecoding(serialno);
            }
        }

        var content = Oggz.stream_get_content(oggz, serialno);

        if (!hasVideo && content == OGGZ_CONTENT_THEORA) {
            hasVideo = true;
            videoCodec = content;
            videoCodecName = "theora";
            videoStream = serialno;
            callback_video_packet(packet.op.packet, packet.op.bytes, -1, -1, 0);
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
    
            var ret = Skeleton.decode_header(Pointer.addressOf(skeleton), Pointer.addressOf(packet.op));
            if (ret == 0) {
                skeletonHeadersComplete = 1;
            } else if (ret > 0) {
                // Just keep going
            } else {
                //printf("Invalid ogg skeleton track data? %d\n", ret);
                return OGGZ_STOP_ERR;
            }
        }

        return OGGZ_CONTINUE;
    }


    public function is_keyframe_theora() {
       var granulepos = Oggz.tell_granulepos(oggz);
       var granuleshift = Oggz.get_granuleshift(oggz, videoStream);
    }
}