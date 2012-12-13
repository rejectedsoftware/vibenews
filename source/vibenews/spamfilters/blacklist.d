module vibenews.spamfilters.blacklist;

import vibenews.vibenews;


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
			if( ip in m_blockedIPs )
				return true;
		return false;
	}

	bool checkForRevoke(ref const Article)
	{
		return false;
	}
}
