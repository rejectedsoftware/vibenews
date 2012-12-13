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
	string hostName;
	string title;

	SpamFilter[] spamFilters;

	void setSpamSettings(Json json)
	{
		foreach( string key, value; json )
		{
			foreach( flt; spamFilters )
				if( flt.id == key )
					flt.setSettings(value);
		}
	}
}

