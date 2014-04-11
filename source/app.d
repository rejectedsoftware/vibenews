/**
	Application entry point for the vibenews forum server.

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
import vibe.d;

import vibenews.nntp.server;
import antispam.filters.bayes;
import antispam.filters.blacklist;
import vibenews.admin;
import vibenews.controller;
import vibenews.news;
import vibenews.vibenews;
import vibenews.web;

NewsInterface s_server;
AdminInterface s_adminInterface;
WebInterface s_webInterface;

version(unittest) {} else
shared static this()
{
	auto settings = new VibeNewsSettings;
	settings.spamFilters ~= new BlackListSpamFilter;
	settings.spamFilters ~= new BayesSpamFilter;

	if( existsFile("settings.json") ){
		auto data = stripUTF8Bom(cast(string)openFile("settings.json").readAll());
		auto json = parseJson(data);
		settings.parseSettings(json);
	}

	settings.mailSettings = new SMTPClientSettings;

	auto ctrl = new Controller(settings);
	s_server = new NewsInterface(ctrl);
	s_server.listen();
	s_adminInterface = new AdminInterface(ctrl);
	s_adminInterface.listen();
	s_webInterface = new WebInterface(ctrl);
	s_webInterface.listen();
}
