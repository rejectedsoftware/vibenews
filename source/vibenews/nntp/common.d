/**
	(module summary)

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.nntp.common;

import vibe.core.log;
import vibe.stream.operations;

import std.algorithm;
import std.exception;


class NNTPBodyReader : InputStream {
	private {
		InputStreamProxy m_stream;
		bool m_eof = false;
		ubyte[] m_currLine;
	}

	this(InputStreamProxy stream)
	{
		m_stream = stream;
		readNextLine();
	}

	@property bool empty() { return m_eof; }

	@property ulong leastSize() { return m_currLine.length; }

	@property bool dataAvailableForRead(){
		return m_currLine.length > 0;
	}

	@property ubyte[] peek()
	{
		return m_currLine;
	}

	static if (!is(IOMode)) override void read(scope ubyte[] bytes) { readImpl(bytes); }
	else override size_t read(scope ubyte[] bytes, IOMode) { readImpl(bytes); return bytes.length; }
	alias read = InputStream.read;

	private void readImpl()(scope ubyte[] dst)
	{
		while (dst.length > 0) {
			enforce(!m_eof);
			auto amt = min(dst.length, m_currLine.length);
			dst[0 .. amt] = m_currLine[0 .. amt];
			
			m_currLine = m_currLine[amt .. $];
			dst = dst[amt .. $];
			
			if( m_currLine.length == 0 )
				readNextLine();
		}
	}

	private void readNextLine()()
	{
		enforce(!m_eof);
		m_currLine = m_stream.readLine() ~ cast(const(ubyte)[])"\r\n";
		m_eof = m_currLine == ".\r\n";
		if( m_currLine.startsWith("..") ) m_currLine = m_currLine[1 .. $];
	}
}

deprecated alias NntpBodyReader = NNTPBodyReader;


class NNTPBodyWriter : OutputStream {
	private {
		OutputStreamProxy m_stream;
		bool m_finalized = false;
		int m_lineState = 0;
		static immutable ubyte[] m_lineStateString = cast(immutable(ubyte)[])"\r\n.";
		bool m_empty = true;
	}

	this(OutputStreamProxy stream)
	{
		m_stream = stream;
	}

	static if (!is(IOMode)) override void write(in ubyte[] bytes) { writeImpl(bytes); }
	else override size_t write(in ubyte[] bytes, IOMode) { writeImpl(bytes); return bytes.length; }
	alias write = OutputStream.write;

	private void writeImpl()(in ubyte[] bytes_)
	{
		const(ubyte)[] bytes = bytes_;
		assert(!m_finalized);

		if( bytes.length ){
			if( m_empty && bytes[0] == '.' ){
				m_stream.write("..");
				logDebugV("WS <..>", cast(const(char)[])bytes[0 .. $-m_lineState]);
				bytes = bytes[1 .. $];
			}
			m_empty = false;
		}

		// test any already started prefix
		if( m_lineState > 0 ){
			foreach( i; m_lineState .. min(m_lineStateString.length, bytes.length+m_lineState) ){
				if( bytes[i-m_lineState] != m_lineStateString[i] ){
					m_stream.write(m_lineStateString[0 .. i]);
					bytes = bytes[i-m_lineState .. $];
					logDebugV("WPM <%s>", cast(const(char)[])m_lineStateString[0 .. i]);
					m_lineState = 0;
					break;
				}
			}
			if( m_lineState > 0 ){
				if( m_lineStateString.length > bytes.length+m_lineState ){
					m_lineState += bytes.length;
					bytes = null;
				} else {
					m_stream.write("\r\n..");
					logDebugV("WEM <\\r\\n..>");
					bytes = bytes[m_lineStateString.length-m_lineState .. $];
					m_lineState = 0;
				}
			}
		}

		while( bytes.length ){
			auto idx = bytes.countUntil(m_lineStateString);
			if( idx >= 0 ){
				m_stream.write(bytes[0 .. idx]);
				m_stream.write("\r\n..");
				logDebugV("WMM <%s\\r\\n..>", cast(const(char)[])bytes[0 .. idx]);
				bytes = bytes[idx+m_lineStateString.length .. $];
			} else {
				foreach( i; 1 .. min(m_lineStateString.length, bytes.length) )
					if( bytes[$-i .. $] == m_lineStateString[0 .. i] ){
						m_lineState = cast(int)i;
						break;
					}
				m_stream.write(bytes[0 .. $-m_lineState]);
				logDebugV("WP <%s>", cast(const(char)[])bytes[0 .. $-m_lineState]);
				bytes = null;
			}
		}
	}

	void flush()
	{
		m_stream.flush();
	}

	void finalize()
	{
		if( m_lineState > 0 ) m_stream.write(m_lineStateString[0 .. m_lineState]);
		enforce(!m_finalized);
		m_finalized = true;
		if( m_empty ) m_stream.write(".\r\n");
		else m_stream.write("\r\n.\r\n");
		m_stream.flush();
		logDebugV("WF <\\r\\n.\\r\\n>");
	}

	static if (!is(IOMode)) {
		override void write(InputStream stream, ulong nbytes = 0)
		{
			writeDefault(stream, nbytes);
		}
	}
}

deprecated alias NntpBodyWriter = NNTPBodyReader;
