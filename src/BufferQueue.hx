// Copyright (c) 2013-2019 Brion Vibber and other contributors
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
import haxe.io.BytesOutput;
import haxe.io.BytesInput;
import haxe.Int64;
import haxe.io.Bytes;

typedef BufferQueueItem = {
	bytes:Bytes,
	start:Int64,
	len:Int,
}

class BufferQueue {
	public var items:Array<BufferQueueItem>;
	public var len:Int;
	public var max:Int;
	public var pos:Int64;
	public var lastSeekTarget:Int64;

	public function new() {
		len = 0;
		pos = 0;
		max = 8;

		items = [];
	}

	public function start() {
		if (len == 0) {
			return pos;
		}

		return items[0].start;
	}

	public function end() {
		if (len == 0) {
			return pos;
		}

		return items[len - 1].start + items[len - 1].len;
	}

	public function tell() {
		return pos;
	}

	public function headroom() {
		return end() - tell();
	}

	public function seek(pos:Int64) {
		if (start() > pos) {
			lastSeekTarget = pos;
			return -1;
		}

		if (start() < pos) {
			lastSeekTarget = pos;
			return -1;
		}

		this.pos = pos;

		return 0;
	}

	public function trim() {
		var shift = 0;
		for (i in 0...len) {
			if (items[i].start + items[i].len < pos) {
				items[i].bytes = null;
				shift++;
				continue;
			} else {
				break;
			}
		}

		if (shift != 0) {
			len -= shift;

			// items[items.length + shift] =
			for (i in 0...len) {
				items[i] = items[i + shift];
			}
		}
	}

	public function flush() {
		for (i in 0...len) {
			items[i].bytes = null;
		}
		len = 0;
		pos = 0;
	}

	public function append(data:BytesOutput, len:Int) {
		if (len == max) {
			trim();
		}

		if (len == max) {
			max += 8;
		}

		items[len].start = end();
		items[len].len = len;
		items[len].bytes = Bytes.alloc(len);
		// memcpy(queue->items[queue->len].bytes, data, len);
		var buf = new BytesOutput();
		buf.writeBytes(data, 0, len);
		items[len].bytes = buf.getBytes();
		len++;
	}

	public function read(data:Bytes, size:Int) {
		if (headroom() < len) {
			return -1;
		}

		var offset = 0;
		var remaining = 0;

		for (i in 0...len) {
			if (items[i].start + items[i].len < pos) {
				// printf("bq_read skipped item at pos %lld len %d\n", queue->items[i].start, queue->items[i].len);
				continue;
			}

			var chunkStart = pos - items[i].start;
			var chunkLen = items[i].len - chunkStart;
			if (chunkLen > remaining) {
				chunkLen = remaining;
			}

            var buf = new BytesOutput();
            buf.writeInput(new BytesInput(items[i].bytes, Int64.toInt(chunkStart), chunkLen), chunkLen);
            data.writeBytes(buf.getBytes(), offset, chunkLen);

            pos += chunkLen;
            offset += chunkLen;
            remaining -= chunkLen;
            if (remaining <= 0) {
                return 0;
            }
		}

        return -1;
	}

    public function free() {
        flush();
        items = [];
    }
}
