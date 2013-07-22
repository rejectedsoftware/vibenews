/**
	Application entry point for the vibenews forum server.

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
import vibe.d;

import vibenews.nntp.server;
import vibenews.spamfilters.blacklist;
import vibenews.admin;
import vibenews.controller;
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

	settings.mailSettings = new SMTPClientSettings;

	auto ctrl = new Controller(settings);
	s_server = new NewsInterface(ctrl);
	s_adminInterface = new AdminInterface(ctrl);
	s_webInterface = new WebInterface(ctrl);
}
