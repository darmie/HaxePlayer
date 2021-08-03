package demuxer;

enum abstract Seek(Int) from Int to Int {
	final SEEK_SET = 0; /* set file offset to offset */
	final SEEK_CUR = 1; /* set file offset to current plus offset */
	final SEEK_END = 2; /* set file offset to EOF plus offset */
}
