module vibenews.db;

import vibe.d;

class Controller {
	private {
		MongoDB m_db;
		MongoCollection m_groups;
		MongoCollection m_articles;
		MongoCollection m_threads;
	}

	this()
	{
		m_db = connectMongoDB("127.0.0.1");
		m_groups = m_db["vibenews.groups"];
		m_articles = m_db["vibenews.articles"];
		m_threads = m_db["vibenews.threads"];
	}

	void enumerateGroups(void delegate(size_t idx, Group) cb)
	{
		Group group;
		foreach( idx, bg; m_groups.find(["active": true]) ){
			deserializeBson(group, bg);
			cb(idx, group);
		}
	}

	void enumerateNewGroups(SysTime date, void delegate(size_t idx, Group) del)
	{
		Group group;
		Bson idmatch = Bson(BsonObjectID.createDateID(date));
		foreach( idx, bg; m_groups.find(["_id": Bson(["$gte": idmatch]), "active": Bson(true)]) ){
			deserializeBson(group, bg);
			del(idx, group);
		}
	}

	bool groupExists(string name)
	{
		auto bg = m_groups.findOne(["name": Bson(name), "active": Bson(true)], ["_id": 1]);
		return !bg.isNull();
	}

	Group getGroupByName(string name)
	{
		auto bg = m_groups.findOne(["name": Bson(name), "active": Bson(true)]);
		enforce(!bg.isNull(), "Group "~name~" not found!");
		Group ret;
		deserializeBson(ret, bg);
		return ret;
	}

	void addGroup(Group g)
	{
		m_groups.insert(g);
	}

	void updateGroup(Group g)
	{
		m_groups.update(["_id": g._id], g);
	}

	Article getArticle(string id)
	{
		auto ba = m_articles.findOne(["id": Bson(id), "active": Bson(true)]);
		enforce(!ba.isNull(), "Article "~id~" not found!");
		Article ret;
		deserializeBson(ret, ba);
		return ret;
	}

	Article getArticle(string groupname, long number, bool msgbdy = true)
	{
		auto egrp = escapeGroup(groupname);
		auto nummatch = Bson(number);
		auto ba = m_articles.findOne(["number."~egrp: nummatch, "active": Bson(true)], msgbdy ? null : ["message": 0]);
		enforce(!ba.isNull(), "Article "~to!string(number)~" not found for group "~groupname~"!");
		Article ret;
		deserializeBson(ret, ba);
		return ret;
	}

	void enumerateArticles(string groupname, void delegate(size_t idx, BsonObjectID _id, string msgid, long msgnum) del)
	{
		auto egrp = escapeGroup(groupname);
		auto numquery = serializeToBson(["$exists": true]);
		auto query = serializeToBson(["number."~egrp: numquery, "active": Bson(true)]);
		auto order = serializeToBson(["number."~egrp: 1]);
		foreach( idx, ba; m_articles.find(["query": query, "orderby": order], ["_id": 1, "id": 1, "number": 1]) ){
			del(idx, ba["_id"].get!BsonObjectID, ba["id"].get!string, ba["number"][escapeGroup(groupname)].get!long);
		}
	}

	void enumerateArticles(string groupname, long from, long to, void delegate(size_t idx, Article art) del)
	{
		Article art;
		string gpne = escapeGroup(groupname);
		auto numquery = serializeToBson(["$gte": from, "$lte": to]);
		auto query = serializeToBson(["number."~gpne: numquery, "active": Bson(true)]);
		auto order = serializeToBson(["number."~gpne: 1]);
		foreach( idx, ba; m_articles.find(["query": query, "orderby": order], ["message": 0]) ){
			ba["message"] = Bson(BsonBinData(BsonBinData.Type.Generic, null));
			if( ba["number"][gpne].get!long > to )
				break;
			deserializeBson(art, ba);
			del(idx, art);
		}
	}

	void enumerateNewArticles(string groupname, SysTime date, void delegate(size_t idx, BsonObjectID _id, string msgid, long msgnum) del)
	{
		Bson idmatch = Bson(BsonObjectID.createDateID(date));
		Bson groupmatch = Bson(true);
		auto egrp = escapeGroup(groupname);
		auto query = serializeToBson(["_id" : Bson(["$gte": idmatch]), "number."~egrp: Bson(["$exists": groupmatch]), "active": Bson(true)]);
		auto order = serializeToBson(["number."~egrp: 1]);
		foreach( idx, ba; m_articles.find(["query": query, "orderby": order], ["_id": 1, "id": 1, "number": 1]) ){
			del(idx, ba["_id"].get!BsonObjectID, ba["id"].get!string, ba["number"][escapeGroup(groupname)].get!long);
		}
	}

	void enumerateAllArticles(string groupname, int first, int count, void delegate(ref Article art) del)
	{
		auto egrp = escapeGroup(groupname);
		auto query = serializeToBson(["number."~egrp: ["$exists": true]]);
		auto order = serializeToBson(["number."~egrp: 1]);
		foreach( idx, ba; m_articles.find(["query": query, "orderby": order], null, QueryFlags.None, first, count) ){
			Article art;
			deserializeBson(art, ba);
			del(art);
			if( idx == count-1 ) break;
		}
	}

	ulong getAllArticlesCount(string groupname)
	{
		return m_articles.count(["number."~escapeGroup(groupname): ["$exists": true]]);
	}

	void postArticle(Article art)
	{
		string relay_version = art.getHeader("Relay-Version");
		string posting_version = art.getHeader("Posting-Version");
		string from = art.getHeader("From");
		string date = art.getHeader("Date");
		string[] newsgroups = commaSplit(art.getHeader("Newsgroups"));
		string subject = art.getHeader("Subject");
		string messageid = art.getHeader("Message-ID");
		string path = art.getHeader("Path");

		if( messageid.length == 0 ) art.addHeader("Message-ID", art.id);
		art.messageLength = art.message.length;
		art.messageLines = countLines(art.message);

		if( messageid.length )
			art.id = messageid;

		foreach( grp; newsgroups ){
			m_groups.update(["name": grp], ["$inc": ["articleCount": 1]]);
			auto bgpre = m_groups.findAndModify(["name": grp], ["$inc": ["articleNumberCounter": 1]], ["articleNumberCounter": 1]);
			if( bgpre.isNull() ) continue; // ignore non-existant groups
			logDebug("GRP: %s", bgpre.get!Json.toString());
			long artnum = bgpre.articleNumberCounter.get!long + 1;
			art.number[escapeGroup(grp)] = artnum;
			m_groups.update(["name": Bson(grp), "maxArticleNumber": serializeToBson(["$lt": artnum])], ["$set": ["maxArticleNumber": artnum]]);
		}

		m_articles.insert(art);
	}

	void repairGroupNumbers()
	{
		foreach( grp; m_groups.find(Bson.EmptyObject) ){
			auto grpname = escapeGroup(grp.name.get!string);
			auto numbername = "number." ~ grpname;

			auto artquery = serializeToBson([numbername: Bson(["$exists": Bson(true)]), "active": Bson(true)]);
			auto artcnt = m_articles.count(artquery);
			m_groups.update(["_id": grp._id, "articleCount": grp.articleCount], ["$set": ["articleCount": artcnt]]);

			auto first_art = m_articles.findOne(["query": artquery, "orderby": serializeToBson([numbername: 1])], ["number": 1]);
			auto last_art = m_articles.findOne(["query": artquery, "orderby": serializeToBson([numbername: -1])], ["number": 1]);
			if( first_art.isNull() ) continue;
			assert(!last_art.isNull());

			m_groups.update(["_id": grp._id, "minArticleNumber": grp.minArticleNumber], ["$set": ["minArticleNumber": first_art.number[grpname]]]);
			m_groups.update(["_id": grp._id, "maxArticleNumber": grp.maxArticleNumber], ["$set": ["maxArticleNumber": last_art.number[grpname]]]);
		}
	}

	void deactivateArticle(BsonObjectID artid)
	{
		auto oldart = m_articles.findAndModify!(BsonObjectID[string], bool[string][string], typeof(null))(["_id": artid], ["$set": ["active": false]]);
		if( !oldart.active.get!bool ) return; // was already deactivated

		// update the group counters
		foreach( string gname, num; oldart.number ){
			string numfield = "number."~gname;
			auto groupname = Bson(unescapeGroup(gname));
			auto articlequery = Bson([numfield: Bson(["$exists": Bson(true)]), "active": Bson(true)]);
			m_groups.update(["name": groupname], ["$inc": ["articleCount": -1]]);
			auto g = m_groups.findOne(["name": groupname]);
			if( g.minArticleNumber == num ){
				auto minorder = serializeToBson([numfield: 1]);
				auto minart = m_articles.findOne(["query": articlequery, "orderby": minorder]);
				long newnum = minart.number[gname].get!long;
				m_groups.update(["name": groupname, "minArticleNumber": num], ["$set": ["minArticleNumber": newnum]]);
			}
			if( g.maxArticleNumber == num ){
				auto maxorder = serializeToBson([numfield: -1]);
				auto maxart = m_articles.findOne(["query": articlequery, "orderby": maxorder]);
				long newnum = maxart.number[gname].get!long;
				m_groups.update(["name": groupname, "maxArticleNumber": num], ["$set": ["maxArticleNumber": newnum]]);
			}
		}
	}

	void activateArticle(BsonObjectID artid)
	{
		auto oldart = m_articles.findAndModify!(BsonObjectID[string], bool[string][string], typeof(null))(["_id": artid], ["$set": ["active": true]]);
		if( oldart.active.get!bool ) return; // was already deactivated

		// update the group counters
		foreach( string gname, num; oldart.number ){
			string numfield = "number."~gname;
			auto groupname = Bson(unescapeGroup(gname));
			m_groups.update(["name": groupname], ["$inc": ["articleCount": 1]]);
			m_groups.update(["name": groupname, "maxArticleNumber": Bson(["$lt": num])], ["$set": ["maxArticleNumber": num]]);
			m_groups.update(["name": groupname, "minArticleNumber": Bson(["$gt": num])], ["$set": ["minArticleNumber": num]]);
		}
	}

	void deleteArticle(BsonObjectID artid)
	{
		deactivateArticle(artid);
		m_articles.remove(["_id": artid]);
	}

	// deletes all inactive articles from the group
	void purgeGroup(string name)
	{
		m_articles.remove(["active": Bson(false), "number."~escapeGroup(name): Bson(["$exists": Bson(true)])]);
	}
}


string escapeGroup(string str)
{
	return str.translate(['.': '#'], null);
}

string unescapeGroup(string str)
{
	return str.translate(['#': '.'], null);
}

string[] commaSplit(string str)
{
	string[] ret;
	while(true){
		auto idx = str.countUntil(',');
		if( idx > 0 ){
			ret ~= strip(str[0 .. idx]);
			str = str[idx+1 .. $];
		} else {
			ret ~= strip(str);
			break;
		}
	}
	return ret;
}

long countLines(const(ubyte)[] str)
{
	long sum = 1;
	while(str.length > 0){
		auto idx = str.countUntil('\n');
		str = str[idx+1 .. $];
		sum++;
	}
	return sum;
}


struct Article {
	BsonObjectID _id;
	string id; // "<asdasdasd@server.com>"
	bool active = true;
	long[string] number; // num[groupname]
	ArticleHeader[] headers;
	ubyte[] message;
	long messageLength;
	long messageLines;
	string peerAddress;

	string getHeader(string name)
	const {
		foreach( h; headers )
			if( icmp(h.key, name) == 0 )
				return h.value;
		return null;
	}

	bool hasHeader(string name)
	const {
		foreach( h; headers )
			if( icmp(h.key, name) == 0 )
				return true;
		return false;
	}

	void addHeader(string name, string value) { headers ~= ArticleHeader(name, value); }
}

struct ArticleHeader {
	string key;
	string value;
}

struct Group {
	BsonObjectID _id;
	bool active = true;
	string name;
	string description;
	long articleCount = 0;
	long minArticleNumber = 1;
	long maxArticleNumber = 0;
	long articleNumberCounter = 0;
	string username;
	string passwordHash;
}

