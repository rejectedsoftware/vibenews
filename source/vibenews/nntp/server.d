module vibenews.nntp.server;

import vibenews.nntp.common;
import vibenews.nntp.status;

import vibe.core.log;
import vibe.core.net;
import vibe.stream.counting;
import vibe.stream.ssl;

import std.algorithm;
import std.conv;
import std.exception;
import std.string;


void listenNntp(NntpServerSettings settings, void delegate(NntpServerRequest, NntpServerResponse) command_handler)
{
	void handleNntpConnection(TcpConnection conn)
	{
		bool tls_active = false;
		if( settings.sslCert.length || settings.sslKey.length ){
			auto ctx = new SslContext(settings.sslCert, settings.sslKey, SSLVersion.TLSv1);
			assert(false);
			/*logInfo("accepting");
			conn.acceptSSL(ctx);
			logInfo("accepted");
			tls_active = true;*/
		}

		conn.write("200 Welcome on VibeNews!\r\n");
		logDebug("welcomed");

		while(conn.connected){
			auto res = new NntpServerResponse(conn, tls_active, settings.sslCert, settings.sslKey);
			logDebug("waiting for request");
			auto ln = cast(string)conn.readLine();
			logDebug("REQUEST: %s", ln);
			auto params = ln.spaceSplit();
			if( params.length < 1 ){
				res.status = NntpStatus.BadCommand;
				res.statusText = "Expected command";
				res.writeVoidBody();
				res.finalize();
				continue;
			}
			auto cmd = params[0].toLower();
			params = params[1 .. $];
			if( cmd == "quit" ){
				res.status = NntpStatus.ClosingConnection;
				res.statusText = "Bye bye!";
				res.writeVoidBody();
				res.finalize();
				conn.close();
				return;
			}
			auto req = new NntpServerRequest(conn);
			req.command = cmd;
			req.parameters = params;
			req.peerAddress = conn.peerAddress;
			try {
				command_handler(req, res);
			} catch( Exception e ){
				logWarn("NNTP request exception: %s", e.toString());
				if( !res.m_headerWritten ){
					res.status = NntpStatus.InternalError;
					res.writeVoidBody();
				}
			}
			res.finalize();
		}
		logDebug("disconnected");
	}


	foreach( addr; settings.bindAddresses )
		listenTcp(settings.port, &handleNntpConnection, addr);
}

class NntpServerSettings {
	ushort port = 119; // SSL port is 563
	string[] bindAddresses = ["0.0.0.0"];
	string host = "localhost"; // host name
	string sslCert;
	string sslKey;
}

class NntpServerRequest {
	private {
		InputStream m_stream;
		NntpBodyReader m_reader;
	}

	string command;
	string[] parameters;
	string peerAddress;

	this(InputStream str)
	{
		m_stream = str;
	}

	void enforceNParams(size_t n, string syntax = null) {
		enforce(parameters.length == n, NntpStatus.CommandSyntaxError, syntax ? "Expected "~syntax : "Wrong number of arguments.");
	}

	void enforceNParams(size_t nmin, size_t nmax, string syntax = null) {
		enforce(parameters.length >= nmin && parameters.length <= nmax,
			NntpStatus.CommandSyntaxError, syntax ? "Expected "~syntax : "Wrong number of arguments.");
	}

	void enforce(bool cond, NntpStatus status, string message)
	{
		.enforce(cond, message);
	}

	@property InputStream bodyReader()
	{
		if( !m_reader ) m_reader = new NntpBodyReader(m_stream);
		return m_reader;
	}
}

class NntpServerResponse {
	private {
		TcpConnection m_stream;
		NntpBodyWriter m_bodyWriter;
		string m_certFile;
		string m_keyFile;
		bool m_headerWritten = false;
		bool m_bodyWritten = false;
		bool m_tlsActive = false;
	}

	int status;
	string statusText;

	this(TcpConnection stream, bool tlsactive, string ssl_cert_file, string ssl_key_file)
	{
		m_tlsActive = tlsactive;
		m_certFile = ssl_cert_file;
		m_keyFile = ssl_key_file;
		m_stream = stream;
	}

	void restart()
	{
		finalize();
		m_headerWritten = false;
	}

	void writeVoidBody()
	{
		assert(!m_bodyWritten);
		assert(!m_headerWritten);
		writeHeader();
	} 

	@property OutputStream bodyWriter()
	{
		if( !m_headerWritten ) writeHeader();
		if( !m_bodyWriter ) m_bodyWriter = new NntpBodyWriter(m_stream);
		return m_bodyWriter;
	}

	void acceptTLS()
	{
		enforce(!m_tlsActive, "TLS already active");
		m_tlsActive = true;
		auto ctx = new SslContext(m_certFile, m_keyFile);
		assert(false);
		//m_stream.acceptSSL(ctx);
	}

	private void writeHeader()
	{
		assert(!m_bodyWritten);
		assert(!m_headerWritten);
		m_headerWritten = true;
		//if( !statusText.length ) statusText = getNntpStatusString(status);
		m_stream.write(to!string(status) ~ " " ~ statusText ~ "\r\n");
		logDebug("%s %s", status, statusText);
	}

	private void finalize()
	{
		if( m_bodyWriter ){
			m_bodyWriter.finalize();
			m_bodyWriter = null;
		}
	}
}


private string[] spaceSplit(string str)
{
	string[] ret;
	str = stripLeft(str);
	while(str.length){
		auto idx = str.countUntil(' ');
		if( idx > 0 ){
			ret ~= str[0 .. idx];
			str = str[idx+1 .. $];
		} else {
			ret ~= str;
			break;
		}
		str = stripLeft(str);
	}
	return ret;
}
