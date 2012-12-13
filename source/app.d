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
	auto settings = new VibeNewsSettings;
	settings.spamFilters ~= new BlackListSpamFilter;

	if( existsFile("settings.json") ){
		auto data = stripUTF8Bom(cast(string)openFile("settings.json").readAll());
		auto json = parseJson(data);
		settings.parseSettings(json);
	}

	//settings.sslCert = "server.crt";
	//settings.sslKey = "server.key";

	auto ctrl = new Controller;
	s_server = new NewsInterface(ctrl, settings);
	s_adminInterface = new AdminInterface(ctrl, settings);
	s_webInterface = new WebInterface(ctrl, settings);
}
