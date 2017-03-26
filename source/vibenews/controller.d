/**
	(module summary)

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.controller;

import vibenews.nntp.status;
import vibenews.vibenews;

import vibe.vibe;

import antispam.antispam;
import userman.db.controller;

import std.algorithm;
import std.array;
import std.base64;
import std.encoding : sanitize;
import std.string;


class Controller {
	private {
		VibeNewsSettings m_settings;
		MongoCollection m_groups;
		MongoCollection m_groupCategories;
		MongoCollection m_articles;
		MongoCollection m_threads;
		UserManController m_userdb;
	}

	this(VibeNewsSettings vnsettings)
	{
		m_settings = vnsettings;

		auto settings = new UserManSettings;
		settings.useUserNames = false;
		settings.databaseURL = "mongodb://127.0.0.1:27017/"~m_settings.databaseName;
		settings.serviceName = m_settings.title;
		settings.serviceUrl = URL("http://"~m_settings.hostName~"/");
		settings.serviceEmail = "info@"~m_settings.hostName;
		settings.mailSettings = m_settings.mailSettings;
		settings.requireAccountValidation = m_settings.requireAccountValidation;
		m_userdb = createUserManController(settings);

		auto db = connectMongoDB("127.0.0.1").getDatabase(m_settings.databaseName);
		m_groups = db["groups"];
		m_groupCategories = db["groupCategories"];
		m_articles = db["articles"];
		m_threads = db["threads"];
		//m_users = m_db["vibenews.users"];

		// fixup old article format
		foreach (a; m_articles.find(["number": ["$exists": true]])) {
			GroupRef[string] grprefs;
			foreach (string gname, num; a["number"]) {
				auto grp = m_groups.findOne(["name": unescapeGroup(gname)], ["_id": true]);
				if( grp.isNull() ) continue;

				// create new GroupRef instead of the simple long
				GroupRef grpref;
				grpref.articleNumber = num.get!long;
				grprefs[gname] = grpref;
			}
			// remove the old number field and add the group refs instead
			m_articles.update(["_id": a["_id"]], ["$set": ["groups": grprefs]]);
			m_articles.update(["_id": a["_id"]], ["$unset": ["number": true]]);
		}

		// find old group auth format
		foreach (g; m_groups.find(["passwordHash": ["$exists": true]])){
			Bson[] tags;
			if (g["passwordHash"].length > 0) tags ~= g["name"];
			m_groups.update(["_id": g["_id"]], ["$set": ["readOnlyAuthTags": tags, "readWriteAuthTags": tags]]);
			m_groups.update(["_id": g["_id"]], ["$unset": ["username": true, "passwordHash": true]]);
		}

		// create missing fields
		Bson[string] fields = ["caption": Bson("Group caption")];
		foreach( k, v; fields ){
			m_groups.update([k: ["$exists": false]], ["$set": [k: v]], UpdateFlags.MultiUpdate);
		}

		// upgrade old peerAddress format
		foreach (art; m_articles.find(["$where" : "!Array.isArray(this.peerAddress)"], ["peerAddress": 1]))
			m_articles.update(["_id": art["_id"]], ["$set": ["peerAddress": art["peerAddress"].get!string.split(",").map!strip().array()]]);

		// upgrade missing posterEmail field
		foreach (bart; m_articles.find(["posterEmail": ["$exists": false]])) () @safe {
			Article art;
			art._id = bart["_id"].get!BsonObjectID;
			art.headers = deserializeBson!(ArticleHeader[])(bart["headers"]);
			string name, email;
			decodeEmailAddressHeader(art.getHeader("From"), name, email);
			m_articles.update(["_id": art._id], ["$set": ["posterEmail": email]]);
		} ();

		// fix missing Date headers
		foreach (bart; m_articles.find(["headers": ["$not": ["$elemMatch": ["key": "Date"]]]], ["headers": true])) {
			Article art;
			art._id = bart["_id"].get!BsonObjectID;
			art.headers = deserializeBson!(ArticleHeader[])(bart["headers"]);
			assert(!art.hasHeader("Date"));
			art.addHeader("Date", art._id.timeStamp.toRFC822DateTimeString());
			assert(art.hasHeader("Date"));
			m_articles.update(["_id": art._id], ["$set": ["headers": art.headers]]);
		}


		// create indexes
		import std.typecons : tuple;
		//m_users.ensureIndex([tuple("email", 1)], IndexFlags.Unique);
		m_groups.ensureIndex([tuple("name", 1)], IndexFlags.Unique);
		m_threads.ensureIndex([tuple("groupId", 1)]);
		m_threads.ensureIndex([tuple("firstArticleId", 1)]);
		m_threads.ensureIndex([tuple("lastArticleId", -1)]);
		m_articles.ensureIndex([tuple("id", 1)], IndexFlags.Unique);
		foreach (grp; m_groups.find(Bson.emptyObject, ["name": 1]))
			createGroupIndexes(grp["name"].get!string());
	}

	@property VibeNewsSettings settings() { return m_settings; }

	@property UserManController userManController() { return m_userdb; }

	bool isEmailRegistered(string email) { return m_userdb.isEmailRegistered(email); }

	User getUser(User.ID user_id) { return m_userdb.getUser(user_id); }
	User getUserByEmail(string email) { return m_userdb.getUserByEmail(email); }

	userman.db.controller.Group getAuthGroup(userman.db.controller.Group.ID id) { return m_userdb.getGroup(id); }
	userman.db.controller.Group getAuthGroupByName(string name) { return m_userdb.getGroupByName(name); }

	void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
	{
		m_userdb.enumerateUsers(first_user, max_count, del);
	}

	long getUserCount() { return m_userdb.getUserCount(); }

	void updateUser(User user) { m_userdb.updateUser(user); }
	void deleteUser(User.ID user_id) { m_userdb.deleteUser(user_id); }

	void getUserMessageCount(string email, out ulong active_count, out ulong inactive_count)
	{
		active_count = m_articles.count(["posterEmail": Bson(email), "active": Bson(true)]);
		inactive_count = m_articles.count(["posterEmail": Bson(email), "active": Bson(false)]);
	}

	/***************************/
	/* Group categories        */
	/***************************/

	void enumerateGroupCategories(void delegate(size_t idx, GroupCategory) @safe del)
	{
		size_t idx = 0;
		foreach (bc; m_groupCategories.find()) {
			GroupCategory c;
			deserializeBson(c, bc);
			del(idx++, c);
		}
	}

	GroupCategory getGroupCategory(BsonObjectID id)
	{
		auto bc = m_groupCategories.findOne(["_id": id]);
		enforce(!bc.isNull(), "Invalid category id");
		GroupCategory cat;
		deserializeBson(cat, bc);
		return cat;
	}

	BsonObjectID createGroupCategory(string caption, int index)
	{
		GroupCategory cat;
		cat._id = BsonObjectID.generate();
		cat.caption = caption;
		cat.index = index;
		m_groupCategories.insert(cat);
		return cat._id;
	}

	void updateGroupCategory(BsonObjectID category, string caption, int index, BsonObjectID[] groups)
	{
		GroupCategory cat;
		cat._id = category;
		cat.caption = caption;
		cat.index = index;
		cat.groups = groups;
		m_groupCategories.update(["_id": category], cat);
	}

	void deleteGroupCategory(BsonObjectID id)
	{
		m_groupCategories.remove(["_id": id]);
	}

	/***************************/
	/* Groups                  */
	/***************************/

	void enumerateGroups(void delegate(size_t idx, Group) @safe cb, bool allow_inactive = false)
	{
		Group group;
		size_t idx = 0;
		foreach (bg; m_groups.find()) {
			if( !allow_inactive && !bg["active"].get!bool )
				continue;
			deserializeBson(group, bg);
			cb(idx++, group);
		}
	}

	void enumerateNewGroups(SysTime date, void delegate(size_t idx, Group) @safe del, bool allow_inactive = false)
	{
		Group group;
		Bson idmatch = Bson(BsonObjectID.createDateID(date));
		size_t idx = 0;
		foreach (bg; m_groups.find(["_id": Bson(["$gte": idmatch])])) {
			if( !allow_inactive && !bg["active"].get!bool )
				continue;
			deserializeBson(group, bg);
			del(idx++, group);
		}
	}

	bool groupExists(string name, bool allow_inactive = false)
	{
		auto bg = m_groups.findOne(["name": Bson(name)], ["active": 1]);
		return !bg.isNull() && (allow_inactive || bg["active"].get!bool);
	}

	Group getGroup(BsonObjectID id, bool allow_inactive = false)
	{
		auto bg = m_groups.findOne(["_id": Bson(id)]);
		enforce(!bg.isNull() && (allow_inactive || bg["active"].get!bool), "Unknown group id!");
		Group ret;
		deserializeBson(ret, bg);
		return ret;
	}

	Group getGroupByName(string name, bool allow_inactive = false)
	{
		auto bg = m_groups.findOne(["name": Bson(name)]);
		enforce(!bg.isNull() && (allow_inactive || bg["active"].get!bool), "Group "~name~" not found!");
		Group ret;
		deserializeBson(ret, bg);
		return ret;
	}

	void addGroup(Group g)
	{
		m_groups.insert(g);
		createGroupIndexes(g.name);
	}

	void updateGroup(Group g)
	{
		m_groups.update(["_id": g._id], g);
	}

	void createGroupIndexes()(string grpname)
	{
		import std.typecons : tuple;

		string egrp = escapeGroup(grpname);
		string grpfield = "groups."~egrp;
		m_articles.ensureIndex([tuple(grpfield~".articleNumber", 1)], IndexFlags.Sparse);
		m_articles.ensureIndex([tuple(grpfield~".threadId", 1)], IndexFlags.Sparse);
	}

	/***************************/
	/* Threads                 */
	/***************************/

	long getThreadCount(BsonObjectID group)
	{
		return m_threads.count(["groupId": Bson(group), "firstArticleId": serializeToBson(["$ne": BsonObjectID()])]);
	}

	Thread getThread(BsonObjectID id)
	{
		auto bt = m_threads.findOne(["_id": id]);
		enforce(!bt.isNull(), "Unknown thread id");
		Thread t;
		deserializeBson(t, bt);
		return t;
	}

	Thread getThreadForFirstArticle(string groupname, long articlenum)
	{
		auto art = m_articles.findOne(["groups."~escapeGroup(groupname)~".articleNumber": articlenum], ["_id": 1]);
		enforce(!art.isNull(), "Invalid article group/number");
		auto bt = m_threads.findOne(["firstArticleId": art["_id"]]);
		enforce(!bt.isNull(), "Article is not the first of any thread.");
		Thread t;
		deserializeBson(t, bt);
		return t;
	}

	void enumerateThreads(BsonObjectID group, size_t skip, size_t max_count, void delegate(size_t, Thread) @safe del)
	{
		assert(skip <= int.max);
		size_t idx = skip;
		foreach( bthr; m_threads.find(["groupId": Bson(group), "firstArticleId": serializeToBson(["$ne": BsonObjectID()])], null, QueryFlags.None, cast(int)skip).sort(["lastArticleId": Bson(-1)]) ){
			Thread thr;
			deserializeBson(thr, bthr);
			del(idx, thr);
			if( ++idx >= skip+max_count ) break;
		}
	}

	long getThreadPostCount(BsonObjectID thread, string groupname = null)
	{
		if( !groupname ) groupname = getGroup(getThread(thread).groupId).name;
		return m_articles.count(["groups."~escapeGroup(groupname)~".threadId" : Bson(thread), "active": Bson(true)]);
	}

	void enumerateThreadPosts(BsonObjectID thread, string groupname, size_t skip, size_t max_count, void delegate(size_t, Article) @safe del)
	{
		assert(skip <= int.max);
		size_t idx = skip;
		foreach (bart; m_articles.find(["groups."~escapeGroup(groupname)~".threadId": Bson(thread), "active": Bson(true)], null, QueryFlags.None, cast(int)skip, cast(int)max_count).sort(["_id": Bson(1)])) {
			Article art;
			deserializeBson(art, bart);
			del(idx, art);
			if( ++idx >= skip+max_count ) break;
		}
	}

	long getThreadArticleIndex(BsonObjectID thread_id, long article_number, string group_name = null)
	{
		if( group_name.length == 0 ){
			auto thr = m_threads.findOne(["_id": thread_id], ["groupId": true]);
			enforce(!thr.isNull());
			auto grp = m_groups.findOne(["_id": thr["groupId"]], ["name": true]);
			enforce(!grp.isNull());
			
			group_name = grp["name"].get!string;
		}

		Bson[string] query;
		query["groups."~escapeGroup(group_name)~".threadId"] = Bson(thread_id);
		query["groups."~escapeGroup(group_name)~".articleNumber"] = serializeToBson(["$lt": article_number]);
		query["active"] = Bson(true);

		return m_articles.count(query);
	}

	/***************************/
	/* Articles                */
	/***************************/

	Article getArticle(BsonObjectID id)
	{
		auto ba = m_articles.findOne(["_id": Bson(id), "active": Bson(true)]);
		enforce(!ba.isNull(), "Unknown article id!");
		Article ret;
		deserializeBson(ret, ba);
		return ret;
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
		auto ba = m_articles.findOne(["groups."~egrp~".articleNumber": nummatch, "active": Bson(true)], msgbdy ? null : ["message": 0]);
		enforce(!ba.isNull(), "Article "~to!string(number)~" not found for group "~groupname~"!");
		if( !msgbdy ) ba["message"] = Bson(BsonBinData());
		Article ret;
		deserializeBson(ret, ba);
		return ret;
	}

	GroupRef[string] getArticleGroupRefs(BsonObjectID id)
	{
		auto art = m_articles.findOne(["_id": id], ["groups": 1]);
		enforce(!art.isNull(), "Unknown article id!");
		GroupRef[string] ret;
		deserializeBson(ret, art["groups"]);
		return ret;
	}

	GroupRef[string] getArticleGroupRefs(string group_name, long article_number)
	{
		auto art = m_articles.findOne(["groups."~escapeGroup(group_name)~".articleNumber": article_number], ["groups": 1]);
		enforce(!art.isNull(), "Unknown article id!");
		GroupRef[string] ret;
		deserializeBson(ret, art["groups"]);
		return ret;
	}

	void enumerateArticles(string groupname, void delegate(size_t idx, BsonObjectID _id, string msgid, long msgnum) @safe del)
	{
		auto egrp = escapeGroup(groupname);
		auto numkey = "groups."~egrp~".articleNumber";
		auto numquery = serializeToBson(["$exists": true]);
		size_t idx = 0;
		foreach (ba; m_articles.find([numkey: numquery, "active": Bson(true)], ["_id": 1, "id": 1, "groups": 1]).sort([numkey: 1])) {
			del(idx++, ba["_id"].get!BsonObjectID, ba["id"].get!string, ba["groups"][escapeGroup(groupname)]["articleNumber"].get!long);
		}
	}

	void enumerateArticles(string groupname, long from, long to, void delegate(size_t idx, Article art) @safe del)
	{
		Article art;
		string gpne = escapeGroup(groupname);
		auto numkey = "groups."~gpne~".articleNumber";
		auto numquery = serializeToBson(["$gte": from, "$lte": to]);
		size_t idx = 0;
		foreach (ba; m_articles.find([numkey: numquery, "active": Bson(true)], ["message": 0]).sort([numkey: 1])) {
			ba["message"] = Bson(BsonBinData(BsonBinData.Type.Generic, null));
			if( ba["groups"][gpne]["articleNumber"].get!long > to )
				break;
			deserializeBson(art, ba);
			del(idx++, art);
		}
	}

	void enumerateNewArticles(string groupname, SysTime date, void delegate(size_t idx, BsonObjectID _id, string msgid, long msgnum) @safe del)
	{
		Bson idmatch = Bson(BsonObjectID.createDateID(date));
		Bson groupmatch = Bson(true);
		auto egrp = escapeGroup(groupname);
		auto numkey = "groups."~egrp~".articleNumber";
		auto query = serializeToBson(["_id" : Bson(["$gte": idmatch]), numkey: Bson(["$exists": groupmatch]), "active": Bson(true)]);
		size_t idx = 0;
		foreach (ba; m_articles.find(query, ["_id": 1, "id": 1, "groups": 1]).sort([numkey: 1])) {
			del(idx++, ba["_id"].get!BsonObjectID, ba["id"].get!string, ba["groups"][egrp]["articleNumber"].get!long);
		}
	}

	void enumerateAllArticlesBackwards(string groupname, int first, int count, void delegate(ref Article art) @safe del)
	{
		auto egrp = escapeGroup(groupname);
		auto numkey = "groups."~egrp~".articleNumber";
		logDebug("%s %s", groupname, egrp);
		size_t idx = 0;
		foreach (ba; m_articles.find([numkey: ["$exists": true]], null, QueryFlags.None, first, count).sort([numkey: -1])) {
			Article art;
			deserializeBson(art, ba);
			del(art);
			if (idx++ == count-1) break;
		}
	}

	ulong getAllArticlesCount(string groupname)
	{
		return m_articles.count(["groups."~escapeGroup(groupname)~".articleNumber": ["$exists": true]]);
	}

	void postArticle(ref Article art, User.ID user_id)
	{
		AntispamMessage msg = toAntispamMessage(art);
		bool revoke = false;
		outer:
		foreach( flt; m_settings.spamFilters ) {
			auto status = flt.determineImmediateSpamStatus(msg);
			final switch (status) {
				case SpamAction.amnesty: revoke = false; break outer;
				case SpamAction.pass: break;
				case SpamAction.revoke: revoke = true; break;
				case SpamAction.block: throw new Exception("Article is deemed to be abusive. Rejected.");
			}
		}


		string relay_version = art.getHeader("Relay-Version");
		string posting_version = art.getHeader("Posting-Version");
		string from = art.getHeader("From");
		string from_name, from_email;
		decodeEmailAddressHeader(from, from_name, from_email);
		string date = art.getHeader("Date");
		string[] newsgroups = commaSplit(art.getHeader("Newsgroups"));
		string subject = art.subject;
		string messageid = art.getHeader("Message-ID");
		string path = art.getHeader("Path");
		string reply_to = art.getHeader("In-Reply-To");
		if( reply_to.length == 0 ){
			auto refs = art.getHeader("References").split(" ");
			if( refs.length > 0 ) reply_to = refs[$-1];
		}

		if (messageid.length) art.id = messageid;
		else art.addHeader("Message-ID", art.id);
		if (!date.length) art.addHeader("Date", Clock.currTime(UTC()).toRFC822DateTimeString());
		assert(art.hasHeader("Date"));
		art.messageLength = art.message.length;
		art.messageLines = countLines(art.message);

		enforce(art.message.length > 0, "You must enter a message.");

		// validate sender
		if (user_id == User.ID.init) {
			enforce(!isEmailRegistered(from_email), new NNTPStatusException(NNTPStatus.articleRejected, "Need to log in to send from a registered email address."));
		} else {
			User usr;
			User lusr = m_userdb.getUser(user_id);
			try usr = m_userdb.getUserByEmail(from_email);
			catch (Exception) {}
			enforce(usr.id == user_id, new NNTPStatusException(NNTPStatus.articleRejected, "Not allowed to post with a foreign email address, please use "~lusr.email~"."));
		}

		// validate groups
		foreach( grp; newsgroups ){
			auto bgpre = m_groups.findOne(["name": grp]);
			enforce(!bgpre.isNull(), new NNTPStatusException(NNTPStatus.articleRejected, "Invalid group: "~grp));
			enforce(isAuthorizedForWritingGroup(user_id, grp), new NNTPStatusException(NNTPStatus.articleRejected, "Not allowed to post in "~grp));
		}

		foreach( grp; newsgroups ){
			auto bgpre = m_groups.findAndModify(["name": grp], ["$inc": ["articleNumberCounter": 1]], ["articleNumberCounter": 1]);
			if( bgpre.isNull() ) continue; // ignore non-existant groups
			m_groups.update(["name": grp], ["$inc": ["articleCount": 1]]);
			logDebug("GRP: %s", bgpre.toJson());

			// try to find the thread of any reply-to message
			BsonObjectID threadid;
			auto rart = reply_to.length ? m_articles.findOne(["id": reply_to]) : Bson(null);
			if( !rart.isNull() && !rart["groups"].isNull() ){
				auto gref = rart["groups"][escapeGroup(grp)];
				if( !gref.isNull() ) threadid = gref["threadId"].get!BsonObjectID;
			}

			// create a new thread if necessary
			if( threadid == BsonObjectID() ){
				Thread thr;
				thr._id = BsonObjectID.generate();
				thr.groupId = bgpre["_id"].get!BsonObjectID;
				thr.subject = subject;
				thr.firstArticleId = art._id;
				thr.lastArticleId = art._id;
				m_threads.insert(thr);
				threadid = thr._id;
			} else {
				m_threads.update(["_id": threadid], ["$set": ["lastArticleId": art._id]]);
			}

			GroupRef grpref;
			grpref.articleNumber = bgpre["articleNumberCounter"].get!long + 1;
			grpref.threadId = threadid;
			art.groups[escapeGroup(grp)] = grpref;
			m_groups.update(["name": Bson(grp), "maxArticleNumber": serializeToBson(["$lt": grpref.articleNumber])], ["$set": ["maxArticleNumber": grpref.articleNumber]]);
		}

		m_articles.insert(art);

		markAsSpam(art._id, revoke);

		runTask({
			foreach (flt; m_settings.spamFilters) {
				auto status = flt.determineAsyncSpamStatus(msg);
				final switch (status) {
					case SpamAction.amnesty: markAsSpam(art._id, false); return;
					case SpamAction.pass: break;
					case SpamAction.revoke: revoke = true; break;
					case SpamAction.block: markAsSpam(art._id, true); return;
				}
				if (status == SpamAction.amnesty) break;
				else if (status != SpamAction.pass) {
					return;
				}
			}
			markAsSpam(art._id, revoke);
		});
	}

	void deactivateArticle(BsonObjectID artid)
	{
		auto oldart = m_articles.findAndModify(["_id": artid], ["$set": ["active": false]]);
		if( !oldart["active"].get!bool ) return; // was already deactivated

		// update the group counters
		foreach (string gname, grp; oldart["groups"]) {
			// update the group
			string numfield = "groups."~gname~".articleNumber";
			auto groupname = Bson(unescapeGroup(gname));
			auto articlequery = Bson([numfield: Bson(["$exists": Bson(true)]), "active": Bson(true)]);
			m_groups.update(["name": groupname], ["$inc": ["articleCount": -1]]);
			auto g = m_groups.findOne(["name": groupname]);
			auto num = grp["articleNumber"];
			if( g["minArticleNumber"] == num ){
				auto minorder = serializeToBson([numfield: 1]);
				auto minart = m_articles.findOne(Bson(["query": articlequery, "orderby": minorder]));
				long newnum;
				if (minart.isNull()) newnum = long.max;
				else newnum = minart["groups"][gname]["articleNumber"].get!long;
				m_groups.update(["name": groupname, "minArticleNumber": num], ["$set": ["minArticleNumber": newnum]]);
			}
			if( g["maxArticleNumber"] == num ){
				auto maxorder = serializeToBson([numfield: -1]);
				auto maxart = m_articles.findOne(Bson(["query": articlequery, "orderby": maxorder]));
				long newnum;
				if (!maxart.isNull()) newnum = maxart["groups"][gname]["articleNumber"].get!long;
				else newnum = 0;
				m_groups.update(["name": groupname, "maxArticleNumber": num], ["$set": ["maxArticleNumber": newnum]]);
			}

			// update the matching thread
			auto threadid = grp["threadId"];
			auto newfirstart = m_articles.findOne(serializeToBson(["query": ["groups."~gname~".threadId": threadid, "active": Bson(true)], "orderby": ["_id": Bson(1)]]), ["_id": true]);
			auto newfirstid = newfirstart.isNull() ? BsonObjectID() : newfirstart["_id"].get!BsonObjectID;
			m_threads.update(["_id": threadid, "firstArticleId": oldart["_id"]], ["$set": ["firstArticleId": newfirstid]]);
			auto newlastart = m_articles.findOne(serializeToBson(["query": ["groups."~gname~".threadId": threadid, "active": Bson(true)], "orderby": ["_id": Bson(-1)]]), ["_id": true]);
			auto newlastid = newfirstart.isNull() ? BsonObjectID() : newlastart["_id"].get!BsonObjectID;
			m_threads.update(["_id": threadid, "lastArticleId": oldart["_id"]], ["$set": ["lastArticleId": newlastid]]);
		}
	}

	void activateArticle(BsonObjectID artid)
	{
		auto oldart = m_articles.findAndModify(["_id": artid], ["$set": ["active": true]]);
		if (oldart["active"].get!bool) return; // was already activated by someone else

		// update the group counters
		foreach (string gname, gref; oldart["groups"]) {
			auto num = gref["articleNumber"];
			auto threadid = gref["threadId"];
			string numfield = "groups."~gname~".articleNumber";
			auto groupname = Bson(unescapeGroup(gname));
			m_groups.update(["name": groupname], ["$inc": ["articleCount": 1]]);
			m_groups.update(["name": groupname, "maxArticleNumber": Bson(["$lt": num])], ["$set": ["maxArticleNumber": num]]);
			m_groups.update(["name": groupname, "minArticleNumber": Bson(["$gt": num])], ["$set": ["minArticleNumber": num]]);

			auto first_matches = serializeToBson([["firstArticleId": Bson(["$gt": oldart["_id"]])], ["firstArticleId": Bson(BsonObjectID())]]);
			m_threads.update(["_id": threadid, "$or": first_matches], ["$set": ["firstArticleId": oldart["_id"]]]);
			m_threads.update(["_id": threadid, "lastArticleId": Bson(["$lt": oldart["_id"]])], ["$set": ["lastArticleId": oldart["_id"]]]);
		}
	}

	void deleteArticle(BsonObjectID artid)
	{
		deactivateArticle(artid);
		m_articles.remove(["_id": artid]);
	}

	void reclassifySpam()
	{
		foreach (flt; m_settings.spamFilters)
			flt.resetClassification();
		
		foreach (bart; m_articles.find()) {
			auto art = deserializeBson!Article(bart);
			foreach (flt; m_settings.spamFilters) {
				auto msg = toAntispamMessage(art);
				if (art.hasHeader("X-Spam-Status")) {
					flt.classify(msg, art.getHeader("X-Spam-Status").icmp("yes") == 0);
				} else if (art.active) flt.classify(msg, false);
			}
		}
	}

	void markAsSpam(BsonObjectID article, bool is_spam)
	{
		if (is_spam) deactivateArticle(article);
		else activateArticle(article);

		auto art = deserializeBson!Article(m_articles.findOne(["_id": article]));

		auto msg = toAntispamMessage(art);
		bool was_spam = false;
		if (art.hasHeader("X-Spam-Status")) {
			was_spam = art.getHeader("X-Spam-Status").icmp("yes") == 0;
			if (was_spam == is_spam) return;
			foreach (flt; m_settings.spamFilters)
				flt.classify(msg, was_spam, true);
		}
		foreach (flt; m_settings.spamFilters)
			flt.classify(msg, is_spam, false);

		art.setHeader("X-Spam-Status", is_spam ? "Yes" : "No");
		m_articles.update(["_id": article], ["$set": ["headers": art.headers]]);
	}

	// deletes all inactive articles from the group
	void purgeGroup(string name)
	{
		m_articles.remove(["active": Bson(false), "groups."~escapeGroup(name)~".articleNumber": Bson(["$exists": Bson(true)])]);
	}

	bool isAuthorizedForReadingGroup(User.ID user, string groupname)
	{
		import std.range : chain;
		auto grp = m_groups.findOne(["name": groupname], ["readOnlyAuthTags": 1, "readWriteAuthTags": 1]);
		if (grp.isNull()) return false;
		if (grp["readOnlyAuthTags"].length == 0) return true;
		enforce(user != User.ID.init, "Group does not allow public access.");
		auto usr = m_userdb.getUser(user);
		foreach (ag; chain(grp["readOnlyAuthTags"].get!(Bson[]), grp["readWriteAuthTags"].get!(Bson[]))) {
			auto agid = () @trusted { return getAuthGroupByName(ag.get!string).id; } ();
			foreach (gid; usr.groups)
				if (gid == agid)
					return true;
		}
		return false;
	}

	bool isAuthorizedForWritingGroup(User.ID user, string groupname)
	{
		auto grp = m_groups.findOne(["name": groupname], ["readOnlyAuthTags": 1, "readWriteAuthTags": 1]);
		if (grp.isNull()) return false;
		if (grp["readOnlyAuthTags"].length == 0 && grp["readWriteAuthTags"].length == 0) return true;
		enforce(user != User.ID.init, "Group does not allow public access.");
		auto usr = m_userdb.getUser(user);
		foreach (ag; grp["readWriteAuthTags"]) {
			auto agid = () @trusted { return getAuthGroupByName(ag.get!string).id; } ();
			foreach (gid; usr.groups)
				if (gid == agid)
					return true;
		}
		return false;
	}

	/***************************/
	/* DB Repair               */
	/***************************/

	void repairGroupNumbers()
	{
		foreach (grp; m_groups.find()) {
			logInfo("Repairing group numbers of %s:", grp["name"].get!string);
			auto grpname = escapeGroup(grp["name"].get!string);
			auto numbername = "groups."~grpname~".articleNumber";

			auto artquery = serializeToBson([numbername: Bson(["$exists": Bson(true)]), "active": Bson(true)]);
			auto artcnt = m_articles.count(artquery);
			logInfo("  article count: %s", artcnt);
			m_groups.update(["_id": grp["_id"], "articleCount": grp["articleCount"]], ["$set": ["articleCount": artcnt]]);

			auto first_art = m_articles.findOne(Bson(["$query": artquery, "$orderby": serializeToBson([numbername: 1])]), ["groups": 1]);
			auto last_art = m_articles.findOne(Bson(["$query": artquery, "$orderby": serializeToBson([numbername: -1])]), ["groups": 1]);

			auto first_art_num = first_art.isNull() ? 1 : first_art["groups"][grpname]["articleNumber"].get!long;
			auto last_art_num = last_art.isNull() ? 0 : last_art["groups"][grpname]["articleNumber"].get!long;
			assert(first_art.isNull() == last_art.isNull());

			logInfo("  first article: %s", first_art_num);
			logInfo("  last article: %s", last_art_num);

			m_groups.update(["_id": grp["_id"], "minArticleNumber": grp["minArticleNumber"]], ["$set": ["minArticleNumber": first_art_num]]);
			m_groups.update(["_id": grp["_id"], "maxArticleNumber": grp["maxArticleNumber"]], ["$set": ["maxArticleNumber": last_art_num]]);
		}

		logInfo("Repair of group numbers finished.");
	}

	void repairThreads()
	{
		m_threads.remove(Bson.emptyObject);

		foreach (ba; m_articles.find(["active": Bson(true)]).sort(["_id": Bson(1)])) () @safe {
			Article a;
			deserializeBson(a, ba);

			// extract reply-to and subject headers
			string repl = a.getHeader("In-Reply-To");
			string subject = a.subject;
			if( repl.length == 0 ){
				auto refs = a.getHeader("References").split(" ");
				if( refs.length > 0 ) repl = refs[$-1];
			}
			auto rart = repl.length ? m_articles.findOne(["id": repl]) : Bson(null);

			foreach (gname; trustedRange(() @system => a.groups.byKey())) ()@safe{
				auto grp = m_groups.findOne(["name": unescapeGroup(gname)], ["_id": true]);
				//if( grp.isNull() ) continue;

				BsonObjectID threadid;

				// try to find the thread of any reply-to message
				if( !rart.isNull() ){
					auto gref = rart["groups"][gname];
					if( !gref.isNull() && m_threads.count(["_id": gref["threadId"]]) > 0 )
						threadid = gref["threadId"].get!BsonObjectID;
				}

				// otherwise create a new thread
				if( threadid == BsonObjectID() ){
					Thread thr;
					thr._id = BsonObjectID.generate();
					thr.groupId = grp["_id"].get!BsonObjectID;
					thr.subject = subject;
					thr.firstArticleId = a._id;
					thr.lastArticleId = a._id;
					m_threads.insert(thr);

					threadid = thr._id;
				} else {
					m_threads.update(["_id": threadid], ["$set": ["lastArticleId": a._id]]);
				}

				m_articles.update(["_id": a._id], ["$set": ["groups."~gname~".threadId": threadid]]);
			}();
		}();
	}

}

AntispamMessage toAntispamMessage(in ref Article art)
@safe {
	AntispamMessage msg;
	foreach (hdr; art.headers) msg.headers[hdr.key] = hdr.value;
	msg.message = art.message;
	msg.peerAddress = art.peerAddress;
	return msg;
}


string escapeGroup(string str)
@safe {
	return str.translate(['.': '#'], null);
}

string unescapeGroup(string str)
@safe {
	return str.translate(['#': '.'], null);
}

string[] commaSplit(string str)
@safe {
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
@safe {
	long sum = 1;
	while(str.length > 0){
		auto idx = str.countUntil('\n');
		if( idx < 0 ) break;
		str = str[idx+1 .. $];
		sum++;
	}
	return sum;
}


struct Article {
	BsonObjectID _id;
	string id; // "<asdasdasd@server.com>"
	bool active = true;
	string posterEmail;
	GroupRef[string] groups; // num[groupname]
	ArticleHeader[] headers;
	ubyte[] message;
	long messageLength;
	long messageLines;
	string[] peerAddress; // list of hops starting from the original client

	@safe:

	@property string subject() const @trusted { return sanitize(decodeEncodedWords(getHeader("Subject"))); }

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

	void addHeader(string name, string value)
	{
		assert(!hasHeader(name));
		headers ~= ArticleHeader(encode(name), encode(value));
	}

	void setHeader(string name, string value)
	{
		foreach (ref h; headers)
			if (icmp(h.key, name) == 0) {
				h.value = encode(value);
				return;
			}
		addHeader(name, value);
	}

	static string encode(string str)
	{
		size_t first_non_ascii = size_t.max, last_non_ascii = 0;
		foreach( i; 0 .. str.length )
			if( (str[i] & 0x80) ){
				if( first_non_ascii == size_t.max )
					first_non_ascii = i;
				last_non_ascii = i;
			}
		if( last_non_ascii < first_non_ascii ) return str;

		auto non_ascii = str[first_non_ascii .. last_non_ascii+1];

		return format("%s=?UTF-8?B?%s?=%s", str[0 .. first_non_ascii],
			cast(const(char)[])Base64.encode(cast(const(ubyte)[])non_ascii),
			str[last_non_ascii+1 .. $]);
	}
}

struct GroupRef {
	long articleNumber;
	BsonObjectID threadId;
}

struct ArticleHeader {
	string key;
	string value;
}

struct GroupCategory {
	BsonObjectID _id;
	string caption;
	int index;
	BsonObjectID[] groups;
}

struct Group {
	BsonObjectID _id;
	bool active = true;
	string name;
	string caption;
	string description;
	long articleCount = 0;
	long minArticleNumber = 1;
	long maxArticleNumber = 0;
	long articleNumberCounter = 0;
	string[] readOnlyAuthTags;
	string[] readWriteAuthTags;
}

struct Thread {
	BsonObjectID _id;
	BsonObjectID groupId;
	string subject;
	BsonObjectID firstArticleId;
	BsonObjectID lastArticleId;
}

enum authGroupPrefix = "vibenews.authgroup.";


private auto trustedRange(R)(scope R delegate() rng)
@trusted {
	static struct TR {
		R _rng;
		bool empty() @trusted { return _rng.empty; }
		auto front() @trusted { return _rng.front; }
		void popFront() @trusted { _rng.popFront(); }
	}

	return TR(rng());
}
