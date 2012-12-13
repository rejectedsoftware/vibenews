import vibe.d;

import vibenews.nntp.server;
import vibenews.spamfilters.blacklist;
import vibenews.admin;
import vibenews.db;
import vibenews.news;
import vibenews.vibenews;
import vibenews.web;

NewsInterface s_server;
AdminInterface s_adminInterface;
WebInterface s_webInterface;


static this()
{
	auto nntpsettings = new NntpServerSettings;
	auto settings = new VibeNewsSettings;
	settings.title = "VibeNews Forum";
	settings.spamFilters ~= new BlackListSpamFilter;

	if( existsFile("settings.json") ){
		auto data = stripUTF8Bom(cast(string)openFile("settings.json").readAll());
		auto json = parseJson(data);
		if( "port" in json ) nntpsettings.port = cast(short)json.port.get!long;
		if( "host" in json ){
			settings.hostName = json.host.get!string;
			nntpsettings.host = json.host.get!string;
		}
		if( "title" in json ) settings.title = json.title.get!string;
		if( auto spam = "spamfilters" in json ) settings.setSpamSettings(*spam);
	}

	//settings.sslCert = "server.crt";
	//settings.sslKey = "server.key";

	auto ctrl = new Controller;
	s_server = new NewsInterface(ctrl, settings);
	s_adminInterface = new AdminInterface(ctrl);
	s_webInterface = new WebInterface(ctrl, settings);
	listenNntp(nntpsettings, &s_server.handleCommand);
}
