/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.vibenews;

public import vibenews.controller : Article;
public import vibe.data.json;
public import vibe.mail.smtp : SmtpClientSettings;


interface SpamFilter {
	@property string id();

	void setSettings(Json settings);

	bool checkForBlock(ref const Article);

	bool checkForRevoke(ref const Article);
}

class VibeNewsSettings {
	// host name used for self-referencing links
	string hostName = "localhost";

	// title of the web forum
	string title = "VibeNews Forum";

	// search engine description of the forum
	string description = "VibeNews based discussion forum with news reader support";

	ushort nntpPort = 119;
	ushort webPort = 8009;
	ushort adminPort = 9009;
	string databaseName = "vibenews";
	SmtpClientSettings mailSettings;

	bool requireAccountValidation = false;

	// enables a google site-search box in the top-right corner of the web forum
	bool googleSearch = false;

	SpamFilter[] spamFilters;

	void parseSettings(Json json)
	{
		if( auto pv = "nntpPort" in json ) nntpPort = cast(short)pv.get!long;
		if( auto pv = "webPort" in json ) webPort = cast(short)pv.get!long;
		if( auto pv = "adminPort" in json ) adminPort = cast(short)pv.get!long;
		if( auto pv = "host" in json ) hostName = pv.get!string;
		if( auto pv = "title" in json ) title = pv.get!string;
		if( auto pv = "description" in json ) description = pv.get!string;
		if( auto pv = "googleSearch" in json ) googleSearch = pv.get!bool;
		if( auto psf = "spamfilters" in json ){
			foreach( string key, value; *psf ){
				foreach( flt; spamFilters )
					if( flt.id == key )
						flt.setSettings(value);
			}
		}
	}
}

