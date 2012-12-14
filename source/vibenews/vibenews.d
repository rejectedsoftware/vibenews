/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.vibenews;

public import vibenews.db : Article;

public import vibe.data.json;


interface SpamFilter {
	@property string id();

	void setSettings(Json settings);

	bool checkForBlock(ref const Article);

	bool checkForRevoke(ref const Article);
}

class VibeNewsSettings {
	string hostName = "localhost";
	string title = "VibeNews Forum";

	ushort nntpPort = 119;
	ushort webPort = 8009;
	ushort adminPort = 9009;

	SpamFilter[] spamFilters;

	void parseSettings(Json json)
	{
		if( "nntpPort" in json ) nntpPort = cast(short)json.port.get!long;
		if( "webPort" in json ) webPort = cast(short)json.port.get!long;
		if( "adminPort" in json ) adminPort = cast(short)json.port.get!long;
		if( "host" in json ) hostName = json.host.get!string;
		if( "title" in json ) title = json.title.get!string;
		if( auto psf = "spamfilters" in json ){
			foreach( string key, value; *psf )
			{
				foreach( flt; spamFilters )
					if( flt.id == key )
						flt.setSettings(value);
			}
		}
	}
}

