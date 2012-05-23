module vibenews.nntp.common;

import vibe.core.log;
import vibe.stream.stream;

import std.algorithm;
import std.exception;


class NntpBodyReader : InputStream {
	private {
		InputStream m_stream;
		bool m_eof = false;
		ubyte[] m_currLine;
	}

	this(InputStream stream)
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

	void read(ubyte[] dst)
	{
		while( dst.length > 0 ){
			enforce(!m_eof);
			auto amt = min(dst.length, m_currLine.length);
			dst[0 .. amt] = m_currLine[0 .. amt];
			
			m_currLine = m_currLine[amt .. $];
			dst = dst[amt .. $];
			
			if( m_currLine.length == 0 )
				readNextLine();
		}
	}

	ubyte[] readLine(size_t max_bytes = 0, string linesep = "\r\n")
	{
		enforce(!m_eof);
		enforce(linesep == "\r\n");
		auto ret = m_currLine[0 .. $-2];
		readNextLine();
		return ret;
	}

	ubyte[] readAll(size_t max_bytes = 0){
		return readAllDefault(max_bytes);
	}

	private void readNextLine()
	{
		enforce(!m_eof);
		m_currLine = m_stream.readLine() ~ cast(ubyte[])"\r\n";
		m_eof = m_currLine == ".\r\n";
		if( m_currLine.startsWith("..") ) m_currLine = m_currLine[1 .. $];
	}
}

class NntpBodyWriter : OutputStream {
	private {
		OutputStream m_stream;
		bool m_finalized = false;
	}

	this(OutputStream stream)
	{
		m_stream = stream;
	}

	void write(in ubyte[] bytes, bool do_flush = true)
	{
		m_stream.write(bytes, do_flush);
		logDebug("<%s>", cast(string)bytes);
	}

	void flush()
	{
		m_stream.flush();
	}

	void finalize()
	{
		enforce(!m_finalized);
		m_finalized = true;
		m_stream.write("\r\n.\r\n");
		logDebug("<.>");
	}

	void write(InputStream stream, ulong nbytes = 0, bool do_flush = true)
	{
		writeDefault(stream, nbytes, do_flush);
	}
}
