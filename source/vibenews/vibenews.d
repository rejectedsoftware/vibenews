/**
	(module summary)

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.vibenews;

public import vibenews.controller : Article;
public import vibe.data.json;
public import vibe.mail.smtp : SMTPClientSettings;

import antispam.antispam;


class VibeNewsSettings {
	// host name used for self-referencing links
	string hostName = "localhost";

	// title of the web forum
	string title = "VibeNews Forum";

	// search engine description of the forum
	string description = "VibeNews based discussion forum with news reader support";

	ushort nntpPort = 119;
	ushort nntpSSLPort = 563;
	deprecated @property ref inout(ushort) nntpSslPort() inout { return nntpSSLPort; }
	ushort webPort = 80;
	ushort adminPort = 9009;
	string databaseName = "vibenews";
	string sslCertFile;
	string sslKeyFile;
	string[] webBindAddresses;
	string[] adminBindAddresses;

	SMTPClientSettings mailSettings;

	bool requireSSL = false;
	deprecated @property ref inout(bool) requireSsl() inout { return requireSSL; }
	bool requireAccountValidation = false;

	// enables a google site-search box in the top-right corner of the web forum
	bool googleSearch = false;
	bool showOverviewAvatars = true;
	bool showLastPostAvatars = false;

	SpamFilter[] spamFilters;

	this()
	{
		import vibe.http.server : HTTPServerSettings;
		auto defaultBindAddresses = (new HTTPServerSettings).bindAddresses;
		webBindAddresses = defaultBindAddresses;
		adminBindAddresses = defaultBindAddresses;
	}

	void parseSettings(Json json)
	{
		import std.conv;

		if( auto pv = "nntpPort" in json ) nntpPort = pv.get!long.to!short;
		if( auto pv = "nntpSslPort" in json ) nntpSSLPort = pv.get!long.to!short; // deprecated
		if( auto pv = "nntpSSLPort" in json ) nntpSSLPort = pv.get!long.to!short;
		if( auto pv = "webPort" in json ) webPort = pv.get!long.to!short;
		if( auto pv = "adminPort" in json ) adminPort = pv.get!long.to!short;
		if( auto pv = "host" in json ) hostName = pv.get!string;
		if( auto pv = "title" in json ) title = pv.get!string;
		if( auto pv = "description" in json ) description = pv.get!string;
		if( auto pv = "sslCertFile" in json ) sslCertFile = pv.get!string;
		if( auto pv = "sslKeyFile" in json ) sslKeyFile = pv.get!string;
		if (auto pv = "requireSSL" in json) requireSSL = pv.get!bool;
		if (auto pv = "requireAccountValidation" in json) requireAccountValidation = pv.get!bool;
		if( auto pv = "googleSearch" in json ) googleSearch = pv.get!bool;
		if (auto pv = "showOverviewAvatars"in json) showOverviewAvatars = pv.get!bool;
		if (auto pv = "showLastPostAvatars"in json) showLastPostAvatars = pv.get!bool;
		if( auto psf = "spamfilters" in json ){
			foreach( string key, value; *psf ){
				foreach( flt; spamFilters )
					if( flt.id == key )
						flt.applySettings(value);
			}
		}
		if( auto pa = "webBindAddresses" in json ){
			webBindAddresses = [];
			foreach( address; *pa )
				webBindAddresses ~= address.get!string;
		}
		if( auto pa = "adminBindAddresses" in json ){
			adminBindAddresses = [];
			foreach( address; *pa )
				adminBindAddresses ~= address.get!string;
		}
	}
}

