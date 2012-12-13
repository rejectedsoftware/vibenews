module vibenews.vibenews;

import vibenews.db;

alias bool delegate(ref const Article) SpamFilter;

class VibeNewsSettings {
	string hostName;
	string title;

	SpamFilter[] immediateSpamFilters;
	SpamFilter[] lazySpamFilters;
}
