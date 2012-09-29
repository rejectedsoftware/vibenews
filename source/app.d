import vibe.d;

import vibenews.admin;
import vibenews.db;
import vibenews.web;
import vibenews.nntp.server;
import vibenews.vibenews;

import std.file;

VibeNewsServer s_server;
AdminInterface s_adminInterface;
WebInterface s_webInterface;


static this()
{
	auto settings = new NntpServerSettings;
	string title = "VibeNews Forum";

	if( exists("settings.json") ){
		auto data = stripUTF8Bom(cast(string)openFile("settings.json").readAll());
		auto json = parseJson(data);
		if( "port" in json ) settings.port = cast(short)json.port.get!long;
		if( "host" in json ){
			g_hostname = json.host.get!string;
			settings.host = json.host.get!string;
		}
		if( "title" in json ) title = json.title.get!string;
	}

	//settings.sslCert = "server.crt";
	//settings.sslKey = "server.key";

	auto ctrl = new Controller;
	s_server = new VibeNewsServer(ctrl);
	s_adminInterface = new AdminInterface(ctrl);
	s_webInterface = new WebInterface(ctrl, title);
	listenNntp(settings, &s_server.handleCommand);
}
