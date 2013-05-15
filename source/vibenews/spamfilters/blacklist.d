/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.spamfilters.blacklist;

import vibenews.message;
import vibenews.vibenews;

import std.array;
import std.string;
import std.uni;


class BlackListSpamFilter : SpamFilter {
	private {
		string[] m_blockedIPs;
		bool[string] m_blockedWords;
	}

	@property string id() { return "blacklist"; }

	void setSettings(Json settings)
	{
		foreach (ip; settings.ips.opt!(Json[]))
			m_blockedIPs ~= ip.get!string;
		foreach (word; settings.words.opt!(Json[]))
			m_blockedWords[word.get!string.toLower()] = true;
	}

	bool checkForBlock(ref const Article art)
	{
		foreach( ip; art.peerAddress )
			foreach( prefix; m_blockedIPs )
				if( ip.startsWith(prefix) )
					return true;

		if (art.getHeader("Subject").containsWords(m_blockedWords))
			return true;
		if (art.decodeMessage().containsWords(m_blockedWords))
			return true;

		return false;
	}

	bool checkForRevoke(ref const Article)
	{
		return false;
	}
}


private bool containsWords(string str, in bool[string] words)
{
	bool inword = false;
	string wordstart;
	while (!str.empty) {
		auto ch = str.front;
		auto isword = ch.isAlpha() || ch.isNumber();
		if (inword && !isword) {
			if (wordstart[0 .. wordstart.length - str.length].toLower() in words)
				return true;
			inword = false;
		} else if (!inword && isword) {
			wordstart = str;
			inword = true;
		}
		str.popFront();
	}

	return true;
}