import vibe.d;

import vibenews.admin;
import vibenews.nntp.server;
import vibenews.vibenews;

import std.file;


static this()
{
	auto settings = new NntpServerSettings;

	if( exists("settings.json") ){
		auto data = stripBom(cast(string)openFile("settings.json").readAll());
		auto json = parseJson(data);
		if( "port" in json ) settings.port = cast(short)json.port.get!long;
		if( "host" in json ){
			g_hostname = json.host.get!string;
			settings.host = json.host.get!string;
		}
	}

	//settings.sslCert = "server.crt";
	//settings.sslKey = "server.key";
	listenNntp(settings, toDelegate(&handleCommand));

	startAdminInterface();
}
