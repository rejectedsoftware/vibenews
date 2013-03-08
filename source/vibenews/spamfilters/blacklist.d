/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.spamfilters.blacklist;

import vibenews.vibenews;

import std.string;


class BlackListSpamFilter : SpamFilter {
	private {
		bool[string] m_blockedIPs;
	}

	@property string id() { return "blacklist"; }

	void setSettings(Json settings)
	{
		foreach( ip; settings.ips.opt!(Json[]) )
			m_blockedIPs[ip.get!string] = true;
	}

	bool checkForBlock(ref const Article art)
	{
		foreach( ip; art.peerAddress )
			foreach( prefix; m_blockedIPs)
				if( ip.startsWith(prefix) )
					return true;
		return false;
	}

	bool checkForRevoke(ref const Article)
	{
		return false;
	}
}
