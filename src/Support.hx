import cpp.Int8;
import cpp.UInt8;
import cpp.RawPointer;
import ogg.OggPage.OggPacket;
import cpp.Pointer;
import cpp.Reference;
import haxe.io.Bytes;

function ogg_import_packet(dest:Reference<OggPacket>, data:RawPointer<UInt8>, len:Int){
    dest.packet = data;
    dest.bytes = len;
    dest.b_o_s = 0;
    dest.e_o_s = 0;
    dest.granulepos = 0;
    dest.packetno = 0;
}