/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.web;

import vibenews.controller;
import vibenews.vibenews;

import userman.web : UserManController, UserManWebInterface;

import vibe.core.core;
import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.data.bson;
import vibe.http.router;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.inet.message;
import vibe.textfilter.markdown;
import vibe.textfilter.urlencode;
import vibe.utils.string;
import vibe.utils.validation;

import std.algorithm : canFind, filter, map, sort;
import std.array;
import std.base64;
import std.conv;
import std.datetime;
import std.encoding;
import std.exception;
import std.string;
import std.utf;


class WebInterface {
	private {
		Controller m_ctrl;
		VibeNewsSettings m_settings;
		UserManWebInterface m_userMan;
		size_t m_postsPerPage = 10;
	}

	this(Controller ctrl)
	{
		m_ctrl = ctrl;
		m_settings = ctrl.settings;

		auto settings = new HttpServerSettings;
		settings.port = m_settings.webPort;
		settings.bindAddresses = ["127.0.0.1"];
		settings.sessionStore = new MemorySessionStore;

		auto router = new UrlRouter;

		m_userMan = new UserManWebInterface(ctrl.userManController);
		m_userMan.register(router);

		router.get("/", &showIndex);
		/*router.post("/login", &login);
		router.get("/logout", &logout);*/
		router.post("/markup", &markupArticle);
		router.get("/groups/:group/", &showGroup);
		router.get("/groups/post", &showPostArticle);
		router.post("/groups/post", &postArticle);
		router.get("/groups/:group/thread/:thread/", &showThread);
		router.get("/groups/:group/post/:post", &showPost);
		router.get("/groups/:group/thread/:thread/:post", &redirectShowPost); // deprecated
		router.get("*", serveStaticFiles("public"));

		listenHttp(settings, router);
	}

	void showIndex(HttpServerRequest req, HttpServerResponse res)
	{
		static struct Info1 {
			string title;
			Category[] categories;
		}
		Info1 info;
		info.title = m_settings.title;

		string[] authTags;
		if( req.session && req.session.isKeySet("userEmail") ){
			auto usr = m_ctrl.getUserByEmail(req.session["userEmail"]);
			authTags = usr.groups;
		}

		Group[] groups;
		m_ctrl.enumerateGroups((idx, grp){
			auto alltags = grp.readOnlyAuthTags ~ grp.readWriteAuthTags;
			if( alltags.length > 0 ){
				bool found = false;
				foreach( t; alltags )
					if( authTags.canFind(t) ){
						found = true;
						break;
					}
				if( !found ) return;
			}
			groups ~= grp;
		});
		m_ctrl.enumerateGroupCategories((idx, cat){ info.categories ~= Category(cat, groups, m_ctrl); });

		if( !info.categories.length ) info.categories ~= Category("All", groups, m_ctrl);

		info.categories.sort!"a.index < b.index"();

		res.renderCompat!("vibenews.web.index.dt",
			HttpServerRequest, "req",
			Info1*, "info")(Variant(req), Variant(&info));
	}

	void login(HttpServerRequest req, HttpServerResponse res)
	{
		auto email = req.form["email"];
		auto password = req.form["password"];

		auto session = res.startSession();
		session["loginEmail"] = email;
		session["loginDisplayEmail"] = email;
		session["loginDisplayName"] = email;

		res.redirect(req.form["redirect"]);
	}

	void logout(HttpServerRequest req, HttpServerResponse res)
	{
		if( req.session ) res.terminateSession();
		res.redirect("/");
	}

	void showGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);

		enforceAuth(req, grp, false);

		static struct Info2 {
			string title;
			GroupInfo group;
			ThreadInfo[] threads;
			size_t page = 0;
			size_t pageSize = 10;
			size_t pageCount;
		}
		Info2 info;
		info.title = m_settings.title;
		if( auto ps = "page" in req.query ) info.page = to!size_t(*ps)-1;

		info.group = GroupInfo(grp, m_ctrl);
		m_ctrl.enumerateThreads(grp._id, info.page*info.pageSize, info.pageSize, (idx, thr){
			info.threads ~= ThreadInfo(thr, m_ctrl, info.pageSize, grp.name);
		});
		
		info.pageCount = (info.group.numberOfTopics + info.pageSize-1) / info.pageSize;

		res.renderCompat!("vibenews.web.view_group.dt",
			HttpServerRequest, "req",
			Info2*, "info")(Variant(req), Variant(&info));
	}

	void showThread(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);

		enforceAuth(req, grp, false);

		static struct Info3 {
			string title;
			string hostName;
			GroupInfo group;
			PostInfo[] posts;
			ThreadInfo thread;
			size_t page;
			size_t postCount;
			size_t pageSize = 10;
			size_t pageCount;
		}
		Info3 info;

		info.title = m_settings.title;
		info.hostName = m_settings.hostName;
		info.pageSize = m_postsPerPage;
		auto threadnum = req.params["thread"].to!long();
		if( auto ps = "page" in req.query ) info.page = to!size_t(*ps) - 1;
		try info.thread = ThreadInfo(m_ctrl.getThreadForFirstArticle(grp.name, threadnum), m_ctrl, info.pageSize, grp.name);
		catch( Exception e ){
			redirectToThreadPost(res, grp.name, threadnum);
			return;
		}
		info.group = GroupInfo(grp, m_ctrl);
		info.postCount = info.thread.postCount;
		info.pageCount = info.thread.pageCount;

		m_ctrl.enumerateThreadPosts(info.thread.id, grp.name, info.page*info.pageSize, info.pageSize, (idx, art){
			Article replart;
			try replart = m_ctrl.getArticle(art.getHeader("In-Reply-To"));
			catch( Exception ){}
			info.posts ~= PostInfo(art, replart, info.group.name);
		});

		res.renderCompat!("vibenews.web.view_thread.dt",
			HttpServerRequest, "req",
			Info3*, "info")(Variant(req), Variant(&info));
	}

	void showPost(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);

		enforceAuth(req, grp, false);

		static struct Info4 {
			string title;
			string hostName;
			GroupInfo group;
			PostInfo post;
			ThreadInfo thread;
		}
		Info4 info;

		auto postnum = req.params["post"].to!long();

		info.title = m_settings.title;
		info.hostName = m_settings.hostName;
		info.group = GroupInfo(grp, m_ctrl);

		auto art = m_ctrl.getArticle(grp.name, postnum);
		Article replart;
		try replart = m_ctrl.getArticle(art.getHeader("In-Reply-To"));
		catch( Exception ){}
		info.post = PostInfo(art, replart, info.group.name);
		info.thread = ThreadInfo(m_ctrl.getThread(art.groups[escapeGroup(grp.name)].threadId), m_ctrl, 0, grp.name);

		res.renderCompat!("vibenews.web.view_post.dt",
			HttpServerRequest, "req",
			Info4*, "info")(Variant(req), Variant(&info));
	}

	void redirectShowPost(HttpServerRequest req, HttpServerResponse res)
	{
		res.redirect("/groups/"~req.params["group"]~"/post/"~req.params["post"], HttpStatus.MovedPermanently);
	}

	void showPostArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.query["group"]);

		enforceAuth(req, grp, true);

		static struct Info5 {
			string title;
			GroupInfo group;
			bool loggedIn = false;
			string name;
			string email;
			string subject;
			string message;
		}
		Info5 info;

		if( req.session ){
			if( req.session.isKeySet("userEmail") ){
				info.loggedIn = true;
				info.name = req.session["userFullName"];
				info.email = req.session["userEmail"];
			} else {
				info.name = req.session["lastUsedName"];
				info.email = req.session["lastUsedEmail"];
			}
		}

		if( "reply-to" in req.query ){
			auto repartnum = req.query["reply-to"].to!long();
			auto repart = m_ctrl.getArticle(grp.name, repartnum);
			info.subject = repart.getHeader("Subject");
			if( !info.subject.startsWith("Re:") ) info.subject = "Re: " ~ info.subject;
			info.message = "On "~repart.getHeader("Date")~", "~PosterInfo(repart.getHeader("From")).name~" wrote:\r\n";
			info.message ~= map!(ln => ln.startsWith(">") ? ">" ~ ln : "> " ~ ln)(splitLines(decodeMessage(repart))).join("\r\n");
			info.message ~= "\r\n\r\n";
		}
		info.title = m_settings.title;
		info.group = GroupInfo(grp, m_ctrl);

		res.renderCompat!("vibenews.web.reply.dt",
			HttpServerRequest, "req",
			Info5*, "info")(Variant(req), Variant(&info));
	}

	void markupArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto msg = req.form["message"];
		validateString(msg, 0, 128*1024, "The message body");
		res.writeBody(filterMarkdown(msg, MarkdownFlags.forumDefault), "text/html");
	}

	void postArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.form["group"]);

		auto user_id = enforceAuth(req, grp, true);

		bool loggedin = req.session && req.session.isKeySet("userEmail");
		string email = loggedin ? req.session["userEmail"] : req.form["email"].strip();
		string name = loggedin ? req.session["userFullName"] : req.form["userEmail"].strip();
		string subject = req.form["subject"].strip();
		string message = req.form["message"];

		validateEmail(email);
		validateString(name, 3, 64, "The poster name");
		validateString(subject, 1, 128, "The message subject");
		validateString(message, 0, 128*1024, "The message body");

		if( !loggedin ){
			enforce(!m_ctrl.isEmailRegistered(email), "The email address is already in use by a registered account. Please log in to use it.");
		}

		Article art;
		art._id = BsonObjectID.generate();
		art.id = "<"~art._id.toString()~"@"~m_settings.hostName~">";
		art.addHeader("Subject", subject);
		art.addHeader("From", "\""~name~"\" <"~email~">");
		art.addHeader("Newsgroups", grp.name);
		art.addHeader("Date", Clock.currTime(UTC()).toRFC822DateTimeString());
		art.addHeader("User-Agent", "VibeNews Web");
		art.addHeader("Content-Type", "text/plain; charset=UTF-8; format=flowed");
		art.addHeader("Content-Transfer-Encoding", "8bit");

		if( auto prepto = "reply-to" in req.form ){
			auto repartnum = to!long(*prepto);
			auto repart = m_ctrl.getArticle(grp.name, repartnum, false);
			auto refs = repart.getHeader("References");
			if( refs.length ) refs ~= " ";
			refs ~= repart.id;
			art.addHeader("In-Reply-To", repart.id);
			art.addHeader("References", refs);
		}

		if( auto pp = "X-Forwarded-For" in req.headers )
			art.peerAddress = split(*pp, ",").map!strip().array() ~ req.peer;
		else art.peerAddress = [req.peer];
		art.message = cast(ubyte[])(message ~ "\r\n");

		foreach( flt; m_settings.spamFilters )
			enforce(!flt.checkForBlock(art), "Article was detected as spam. Rejected.");

		m_ctrl.postArticle(art, user_id);

		if( !req.session ) req.session = res.startSession();
		req.session["lastUsedName"] = name.idup;
		req.session["lastUsedEmail"] = email.idup;

		redirectToThreadPost(res, grp.name, art.groups[escapeGroup(grp.name)].articleNumber, art.groups[escapeGroup(grp.name)].threadId);

		runTask({
			foreach( flt; m_settings.spamFilters )
				if( flt.checkForRevoke(art) ){
					m_ctrl.deactivateArticle(art._id);
					return;
				}
		});
	}

	void redirectToThreadPost(HttpServerResponse res, string groupname, long article_number, BsonObjectID thread_id = BsonObjectID(), HttpStatus redirect_status_code = HttpStatus.Found)
	{
		if( thread_id == BsonObjectID() ){
			auto refs = m_ctrl.getArticleGroupRefs(groupname, article_number);
			thread_id = refs[escapeGroup(groupname)].threadId;
		}
		auto thr = m_ctrl.getThread(thread_id);
		auto first_art_refs = m_ctrl.getArticleGroupRefs(thr.firstArticleId);
		auto first_art_num = first_art_refs[escapeGroup(groupname)].articleNumber;
		auto url = "/groups/"~groupname~"/thread/"~first_art_num.to!string()~"/";
		if( article_number != first_art_num ){
			auto index = m_ctrl.getThreadArticleIndex(thr._id, article_number, groupname);
			auto page = index / m_postsPerPage + 1;
			if( page > 1 ) url ~= "?page="~to!string(page);
			url ~= "#post-"~to!string(article_number);
		}
		res.redirect(url, redirect_status_code);
	}

	BsonObjectID enforceAuth(HttpServerRequest req, ref Group grp, bool read_write)
	{
		BsonObjectID uid;
		string[] authTags;
		if( req.session && req.session.isKeySet("userEmail") ){
			auto usr = m_ctrl.getUserByEmail(req.session["userEmail"]);
			authTags = usr.groups;
			uid = usr._id;
		}

		if( grp.readOnlyAuthTags.empty && grp.readWriteAuthTags.empty )
			return uid;

		auto alltags = grp.readWriteAuthTags;
		if( !read_write ) alltags ~= grp.readOnlyAuthTags;

		bool found = false;
		foreach( t; alltags )
			if( authTags.canFind(t) ){
				found = true;
				break;
			}
		enforce(found, new HttpStatusException(HttpStatus.Forbidden, "Group is protected."));
		return uid;
	}
}

struct GroupInfo {
	this(Group grp, Controller ctrl)
	{
		try {
			auto lastpost = ctrl.getArticle(grp.name, grp.maxArticleNumber);
			lastPoster = PosterInfo(lastpost.getHeader("From"));
			lastPostDate = lastpost.getHeader("Date");//.parseRFC822DateTimeString();
		} catch( Exception ){}

		name = grp.name;
		caption = grp.caption;
		description = grp.description;
		numberOfPosts = cast(size_t)grp.articleCount;
		numberOfTopics = cast(size_t)ctrl.getThreadCount(grp._id);
	}

	string name;
	string caption;
	string description;
	size_t numberOfTopics;
	size_t numberOfPosts;
	PosterInfo lastPoster;
	//SysTime lastPostDate;
	string lastPostDate;
}

struct ThreadInfo {
	this(Thread thr, Controller ctrl, size_t page_size, string groupname)
	{
		id = thr._id;
		subject = thr.subject;
		postCount = cast(size_t)ctrl.getThreadPostCount(thr._id, groupname);
		if( page_size ) pageCount = (postCount + page_size-1) / page_size;
		pageSize = page_size;

		try {
			auto firstpost = ctrl.getArticle(thr.firstArticleId);
			firstPost.poster = PosterInfo(firstpost.getHeader("From"));
			firstPost.date = firstpost.getHeader("Date");//.parseRFC822DateTimeString();
			firstPost.number = firstpost.groups[escapeGroup(groupname)].articleNumber;
			
			auto lastpost = ctrl.getArticle(thr.lastArticleId);
			lastPost.poster = PosterInfo(lastpost.getHeader("From"));
			lastPost.date = lastpost.getHeader("Date");//.parseRFC822DateTimeString();
			lastPost.number = firstpost.groups[escapeGroup(groupname)].articleNumber;
		} catch( Exception ){}
	}

	BsonObjectID id;
	string subject;
	PostInfo firstPost;
	PostInfo lastPost;
	size_t pageSize;
	size_t pageCount;
	size_t postCount;
}

struct PostInfo {
	this(Article art, Article repl_art, string groupname)
	{
		id = art._id;
		subject = art.getHeader("Subject");
		poster = PosterInfo(art.getHeader("From"));
		repliedToPoster = PosterInfo(repl_art.getHeader("From"));
		if( auto pg = escapeGroup(groupname) in repl_art.groups )
			repliedToPostNumber = pg.articleNumber;
		date = art.getHeader("Date");
		message = decodeMessage(art);
		number = art.groups[escapeGroup(groupname)].articleNumber;
	}

	BsonObjectID id;
	long number;
	string subject;
	PosterInfo poster;
	PosterInfo repliedToPoster;
	long repliedToPostNumber;
	//SysTime date;
	string date;
	string message;
}

struct PosterInfo {
	this(string str)
	{
		scope(failure) logDebug("emailbase %s", str);
		Appender!string text;
		while(!str.empty){
			auto idx = str.indexOf("=?");
			if( idx >= 0 ){
				auto end = str.indexOf("?=");
				enforce(end > idx);
				text.put(str[0 .. idx]);
				auto code = str[idx+2 .. end];
				str = str[end+2 .. $];

				idx = code.indexOf('?');
				auto cs = code[0 .. idx];
				auto enc = code[idx+1];
				auto data = code[idx+3 .. $];
				ubyte[] textenc;
				switch(enc){
					default: textenc = cast(ubyte[])data; break;
					case 'B': textenc = Base64.decode(data); break;
					case 'Q': textenc = QuotedPrintable.decode(data, true); break;
				}

				switch(cs){
					default: text.put(sanitizeUTF8(textenc)); break;
					case "UTF-8": text.put(cast(string)textenc); break;
					case "ISO-8859-15": // hack...
					case "ISO-8859-1": string tmp; transcode(cast(Latin1String)textenc, tmp); text.put(tmp); break;
				}
			} else {
				text.put(str);
				break;
			}
		}

		str = text.data().strip();

		scope(failure) logDebug("emaildec %s", str);
		if( str.length ){
			if( str[$-1] == '>' ){
				auto sidx = str.lastIndexOf('<');
				enforce(sidx >= 0);
				email = str[sidx+1 .. $-1];
				str = str[0 .. sidx].strip();

				if( str[0] == '"' ){
					name = str[1 .. $-1];
				} else {
					name = str.strip();
				}
			} else {
				name = str;
				email = str;
			}
		}
		validate(name);
	}

	string name;
	string email;
}

struct Category {
	string title;
	int index;
	GroupInfo[] groups;

	this(GroupCategory cat, Group[] groups, Controller ctrl)
	{
		title = cat.caption;
		index = cat.index;
		foreach( id; cat.groups )
			foreach( grp; groups )
				if( grp._id == id )
					this.groups ~= GroupInfo(grp, ctrl);
	}

	this(string title, Group[] groups, Controller ctrl)
	{
		this.title = title;
		foreach( grp; groups )
			this.groups ~= GroupInfo(grp, ctrl);
	}
}

struct QuotedPrintable {
	static ubyte[] decode(in char[] input, bool in_header = false)
	{
		auto ret = appender!(ubyte[])();
		for( size_t i = 0; i < input.length; i++ ){
			if( input[i] == '=' ){
				auto code = input[i+1 .. i+3];
				i += 2;
				if( code != cast(ubyte[])"\r\n" )
					ret.put(code.parse!ubyte(16));
			} else if( in_header && input[i] == '_') ret.put(' ');
			else ret.put(input[i]);
		}
		return ret.data();
	}
}

string decodeMessage(Article art)
{
	auto msg = art.message;
	switch( art.getHeader("Content-Transfer-Encoding").toLower() ){
		default: break;
		case "quoted-printable": msg = QuotedPrintable.decode(cast(string)msg); break;
		case "base64":
			try msg = Base64.decode(msg);
			catch(Exception e){
				auto dst = appender!(ubyte[])();
				try {
					auto dec = Base64.decoder(msg.filter!(ch => ch != '\r' && ch != '\n')());
					while( !dec.empty ){
						dst.put(dec.front);
						dec.popFront();
					}
				} catch(Exception e){
					dst.put(cast(ubyte[])"\r\n-------\r\nDECODING ERROR: ");
					dst.put(cast(ubyte[])e.toString());
				}
				msg = dst.data();
			}
			break;
	}
	// TODO: do character encoding etc.
	return sanitizeUTF8(msg);
}
