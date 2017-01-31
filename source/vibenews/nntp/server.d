/**
	(module summary)

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.nntp.server;

import vibenews.nntp.common;
import vibenews.nntp.status;

import vibe.core.log;
import vibe.core.net;
import vibe.stream.counting;
import vibe.stream.operations;
import vibe.stream.tls;

import std.algorithm;
import std.conv;
import std.exception;
import std.string;


void listenNNTP(NNTPServerSettings settings, void delegate(NNTPServerRequest, NNTPServerResponse) command_handler)
{
	void handleNNTPConnection(TCPConnection conn)
	{
		StreamProxy stream = conn;

		bool tls_active = false;

		assert(!settings.requireSSL, "requreSsl option is not yet supported.");

		void acceptSsl()
		{
			TLSContext ctx;
			if (settings.sslContext) ctx = settings.sslContext;
			else {
				ctx = createTLSContext(TLSContextKind.server);
				ctx.useCertificateChainFile(settings._sslCertFile);
				ctx.usePrivateKeyFile(settings._sslKeyFile);
			}
			logTrace("accepting SSL");
			stream = createTLSStream(stream, ctx, TLSStreamState.accepting);
			logTrace("accepted SSL");
			tls_active = true;
		}

		if (settings.sslContext || settings._enableSsl) acceptSsl();

		stream.write("200 Welcome on VibeNews!\r\n");
		logDebug("welcomed");

		while(!stream.empty){
			OutputStreamProxy os;
			os = stream;
			auto res = new NNTPServerResponse(os);
			logTrace("waiting for request");
			auto ln = cast(string)stream.readLine();
			logDebug("REQUEST: %s", !ln.startsWith("AUTHINFO") ? ln : "AUTHINFO (...)");
			auto params = ln.spaceSplit();
			if( params.length < 1 ){
				res.status = NNTPStatus.badCommand;
				res.statusText = "Expected command";
				res.writeVoidBody();
				res.finalize();
				continue;
			}
			auto cmd = params[0].toLower();
			params = params[1 .. $];

			if( cmd == "quit" ){
				res.status = NNTPStatus.closingConnection;
				res.statusText = "Bye bye!";
				res.writeVoidBody();
				res.finalize();
				stream.finalize();
				conn.close();
				return;
			}

			if( cmd == "starttls" ){
				if (tls_active) {
					res.status = NNTPStatus.commandUnavailable;
					res.statusText = "TLS already active.";
					res.writeVoidBody();
					res.finalize();
					continue;
				}

				if (!settings.sslContext && !settings._enableSsl) {
					res.status = NNTPStatus.tlsFailed;
					res.statusText = "TLS is not configured for this server.";
					res.writeVoidBody();
					res.finalize();
					continue;
				}

				res.status = NNTPStatus.continueWithTLS;
				res.statusText = "Continue with TLS negotiation";
				res.writeVoidBody();
				res.finalize();

				acceptSsl();
			}

			InputStreamProxy is_;
			is_ = stream;
			auto req = new NNTPServerRequest(is_);
			req.command = cmd;
			req.parameters = params;
			req.peerAddress = conn.peerAddress;
			try {
				command_handler(req, res);
			} catch( NNTPStatusException e ){
				res.status = e.status;
				res.statusText = e.statusText;
				res.writeVoidBody();
			} catch( Exception e ){
				logWarn("NNTP request exception: %s", e.toString());
				if( !res.m_headerWritten ){
					res.status = NNTPStatus.internalError;
					res.statusText = "Internal error: " ~ e.msg;
					res.writeVoidBody();
				}
			}
			res.finalize();
		}
		logDebug("disconnected");
	}


	foreach( addr; settings.bindAddresses ){
		try {
			listenTCP(settings.port, &handleNNTPConnection, addr);
			logInfo("Listening for NNTP%s requests on %s:%s", settings.sslContext || settings._enableSsl ? "S" : "", addr, settings.port);
		} catch( Exception e ) logWarn("Failed to listen on %s:%s", addr, settings.port);
	}
}

deprecated alias listenNNTP = listenNNTP;


class NNTPServerSettings {
	ushort port = 119; // SSL port is 563
	string[] bindAddresses = ["0.0.0.0"];
	string host = "localhost"; // host name
	TLSContext sslContext;
	bool requireSSL = false; // require STARTTLS on unencrypted connections

	deprecated @property ref inout(bool) enableSsl() inout { return _enableSsl; }
	deprecated @property ref inout(string) sslCertFile() inout { return _sslCertFile; }
	deprecated @property ref inout(string) sslKeyFile() inout { return _sslKeyFile; }
	deprecated @property ref inout(bool) requireSsl() inout { return requireSSL; }

	private bool _enableSsl = false;
	private string _sslCertFile;
	private string _sslKeyFile;
}

deprecated alias NntpServerSettings = NNTPServerSettings;


class NNTPServerRequest {
	private {
		InputStreamProxy m_stream;
		NNTPBodyReader m_reader;
	}

	string command;
	string[] parameters;
	string peerAddress;

	this(InputStreamProxy str)
	{
		m_stream = str;
	}

	void enforceNParams(size_t n, string syntax = null) {
		enforce(parameters.length == n, NNTPStatus.commandSyntaxError, syntax ? "Expected "~syntax : "Wrong number of arguments.");
	}

	void enforceNParams(size_t nmin, size_t nmax, string syntax = null) {
		enforce(parameters.length >= nmin && parameters.length <= nmax,
			NNTPStatus.commandSyntaxError, syntax ? "Expected "~syntax : "Wrong number of arguments.");
	}

	void enforce(bool cond, NNTPStatus status, string message)
	{
		.enforce(cond, message);
	}

	@property InputStream bodyReader()
	{
		if( !m_reader ) m_reader = new NNTPBodyReader(m_stream);
		return m_reader;
	}
}

deprecated alias NntpServerRequest = NNTPServerRequest;


class NNTPServerResponse {
	private {
		OutputStreamProxy m_stream;
		NNTPBodyWriter m_bodyWriter;
		bool m_headerWritten = false;
		bool m_bodyWritten = false;
	}

	int status;
	string statusText;

	this(OutputStreamProxy stream)
	{
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
		if( !m_bodyWriter ) m_bodyWriter = new NNTPBodyWriter(m_stream);
		return m_bodyWriter;
	}

	private void writeHeader()
	{
		assert(!m_bodyWritten);
		assert(!m_headerWritten);
		m_headerWritten = true;
		//if( !statusText.length ) statusText = getNNTPStatusString(status);
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

deprecated alias NntpServerResponse = NNTPServerResponse;


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
