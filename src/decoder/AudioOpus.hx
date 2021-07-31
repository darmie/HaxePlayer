package decoder;

import cpp.NativeArray;
import opus.Opus.OpusMultistream;
import OpusHelper.opus_process_header;
import cpp.Reference;
import Support.ogg_import_packet;
import ogg.OggPage.OggPacket;
import cpp.UInt8;
import cpp.RawPointer;
import cpp.Int64;
import opus.Opus.OpusMSDecoder;
import cpp.Pointer;
import ogg.OggPage.OggStreamState;

var audioSampleRate:Float = 0;

var opusHeaders = 0;

var opusStreamState:OggStreamState = untyped __cpp__("ogg_stream_state{}");

var opusDecoder:Pointer<OpusMSDecoder> = null;

var opusMappingFamily:Int = 0;
var opusChannels:Int = 0;

var opusPreskip:Int = 0;

var opusPrevPacketGranpos:Int64 = 0;
var opusGain:Float = 0;

var opusStreams:Int = 0;

/* 120ms at 48000 */
final OPUS_MAX_FRAME_SIZE = 960*6;

function decoder_init(){}

function process_header(data:RawPointer<UInt8>, len:Int, callback:(channels:Int, rate:Float)->Void){
    var oggPacket = OggPacket.init();
    ogg_import_packet(Pointer.addressOf(oggPacket).ref, data, len);

    if (opusHeaders == 0) {
        opusDecoder = opus_process_header(RawPointer.addressOf(oggPacket), Pointer.addressOf(opusMappingFamily).ref, Pointer.addressOf(opusChannels).ref, Pointer.addressOf(opusPreskip).ref, Pointer.addressOf(opusGain).ref, Pointer.addressOf(opusStreams).ref);

        if(opusDecoder != null){
            opusHeaders = 1;
			if (opusGain != 0.0) {
				OpusMultistream.decoder_ctl(opusDecoder, untyped __cpp__("OPUS_SET_GAIN({0}", opusGain));
			}
			opusPrevPacketGranpos = 0;
			opusHeaders = 1;
            // process more headers
			return 1;
        } else {
            // fail!
			return 0;
        }
    } else if (opusHeaders == 1) {
		// comment packet -- discard
		opusHeaders++;
		return 1;
	}

    // opusDecoder should already be initialized
	// Opus has a fixed internal sampling rate of 48000 Hz
    audioSampleRate = 48000;
    if(callback != null){
        callback(opusChannels, audioSampleRate);
    }
    return 1;
}

function process_audio(data:RawPointer<UInt8>, len:Int, callback:(buffers:Array<Array<Float>>, channels:Int, sampleCount:Int)->Void){
    var ret = 0;

    var output:Array<Float> = [];

    var sampleCount = OpusMultistream.decode_float(opusDecoder, data, len, Pointer.ofArray(output).raw, OPUS_MAX_FRAME_SIZE, 0);
    if (sampleCount < 0) {
		//printf("Opus decoding error, code %d\n", sampleCount);
		ret = 0;
	} else {
        var skip = opusPreskip;
        if (skip >= sampleCount) {
			skip = sampleCount;
		}

        // reorder Opus' interleaved samples into two-dimensional [channel][sample] form
        
        var pcm:Array<Float> = [];
        var pcmp:Array<Array<Float>> = [];
        for(c in 0...opusChannels){
            pcmp[c] = untyped __cpp__("{0} + {1} * ({2})", Pointer.addressOf(pcm), c, sampleCount - skip);
            for(s in skip...sampleCount){
                pcmp[c][s - skip] = output[s * opusChannels + c];
            }
        }

        if(callback != null){
            callback(pcmp, opusChannels, sampleCount - skip);
            pcm = [];
            pcmp = [];
        }
        opusPreskip -= skip;
        ret = 1;
    }
    output = [];
    return ret;
}



function decoder_destroy() {
    
}