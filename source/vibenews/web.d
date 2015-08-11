/**
	(module summary)

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.web;

import vibenews.controller;
import vibenews.message;
import vibenews.vibenews;

import antispam.antispam;
import userman.web : UserManController, UserManWebAuthenticator, User, updateProfile, registerUserManWebInterface;

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
import std.variant;


class WebInterface {
	private {
		Controller m_ctrl;
		VibeNewsSettings m_settings;
		UserManWebAuthenticator m_userAuth;
		size_t m_postsPerPage = 10;
	}

	this(Controller ctrl)
	{
		m_ctrl = ctrl;
		m_settings = ctrl.settings;
		m_userAuth = new UserManWebAuthenticator(ctrl.userManController);
	}

	void listen()
	{
		auto settings = new HTTPServerSettings;
		settings.port = m_settings.webPort;
		settings.bindAddresses = m_settings.webBindAddresses;
		settings.sessionStore = new MemorySessionStore;

		auto router = new URLRouter;
		register(router);

		listenHTTP(settings, router);
	}

	void register(URLRouter router)
	{
		router.get("/", &showIndex);
		router.get("/profile", m_userAuth.auth(&showEditProfile));
		router.post("/profile", m_userAuth.auth(&updateProfile));
		router.post("/markup", &markupArticle);
		router.get("/groups", staticRedirect("/"));
		router.get("/groups/", staticRedirect("/"));
		router.get("/groups/:group/", &showGroup);
		router.get("/groups/post", &showPostArticle);
		router.post("/groups/post", &postArticle);
		router.get("/groups/:group/thread/:thread/", &showThread);
		router.get("/groups/:group/post/:post", &showPost);
		router.get("/groups/:group/thread/:thread/:post", &redirectShowPost); // deprecated

		auto settings = new HTTPFileServerSettings;
		static if (is(typeof(router.prefix))) // vibe.d 0.7.20 and up
			settings.serverPathPrefix = router.prefix;
		router.get("*", serveStaticFiles("public", settings));

		registerUserManWebInterface(router, m_ctrl.userManController);
	}

	void showIndex(HTTPServerRequest req, HTTPServerResponse res)
	{
		static struct Info1 {
			VibeNewsSettings settings;
			Category[] categories;
		}
		Info1 info;
		info.settings = m_settings;

		string[] authTags;
		if( req.session && req.session.isKeySet("userEmail") ){
			auto usr = m_ctrl.getUserByEmail(req.session.get!string("userEmail"));
			foreach (g; usr.groups)
				authTags ~= m_ctrl.getAuthGroup(g).name;
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

		res.render!("vibenews.web.index.dt", req, info);
	}

	void showEditProfile(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		struct Info {
			VibeNewsSettings settings;
			Group[] groups;
		}

		enforceHTTP(req.session && req.session.isKeySet("userEmail"), HTTPStatus.forbidden, "Please log in to change your profile information.");

		Info info;
		info.settings = m_settings;
		req.form["email"] = user.email;
		req.form["full_name"] = user.fullName;

		m_ctrl.enumerateGroups((idx, grp){ info.groups ~= grp; });

		res.render!("vibenews.web.edit_profile.dt", req, info);
	}

	void updateProfile(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		try {
			.updateProfile(m_ctrl.userManController, user, req);

			// TODO: notifications
		} catch(Exception e){
			req.params["error"] = e.msg;
			showEditProfile(req, res, user);
			return;
		}

		res.redirect(req.path);
	}

	void showGroup(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);

		if( !enforceAuth(req, res, grp, false) )
			return;

		static struct Info2 {
			VibeNewsSettings settings;
			GroupInfo group;
			ThreadInfo[] threads;
			size_t page = 0;
			size_t pageSize = 10;
			size_t pageCount;
		}
		Info2 info;
		info.settings = m_settings;
		if( auto ps = "page" in req.query ) info.page = to!size_t(*ps)-1;

		info.group = GroupInfo(grp, m_ctrl);
		m_ctrl.enumerateThreads(grp._id, info.page*info.pageSize, info.pageSize, (idx, thr){
			info.threads ~= ThreadInfo(thr, m_ctrl, info.pageSize, grp.name);
		});
		
		info.pageCount = (info.group.numberOfTopics + info.pageSize-1) / info.pageSize;

		res.render!("vibenews.web.view_group.dt", req, info);
	}

	void showThread(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);

		if( !enforceAuth(req, res, grp, false) )
			return;

		static struct Info3 {
			VibeNewsSettings settings;
			GroupInfo group;
			PostInfo[] posts;
			ThreadInfo thread;
			size_t page;
			size_t postCount;
			size_t pageSize = 10;
			size_t pageCount;
		}

		Info3 info;
		info.settings = m_settings;
		info.pageSize = m_postsPerPage;
		auto threadnum = req.params["thread"].to!long();
		if( auto ps = "page" in req.query ) info.page = to!size_t(*ps) - 1;
		try info.thread = ThreadInfo(m_ctrl.getThreadForFirstArticle(grp.name, threadnum), m_ctrl, info.pageSize, grp.name);
		catch( Exception e ){
			redirectToThreadPost(res, (Path(req.path) ~ "../../../").toString(), grp.name, threadnum);
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

		res.render!("vibenews.web.view_thread.dt", req, info);
	}

	void showPost(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);

		if( !enforceAuth(req, res, grp, false) )
			return;

		static struct Info4 {
			VibeNewsSettings settings;
			GroupInfo group;
			PostInfo post;
			ThreadInfo thread;
		}

		auto postnum = req.params["post"].to!long();

		Info4 info;
		info.settings = m_settings;
		info.group = GroupInfo(grp, m_ctrl);

		auto art = m_ctrl.getArticle(grp.name, postnum);
		Article replart;
		try replart = m_ctrl.getArticle(art.getHeader("In-Reply-To"));
		catch( Exception ){}
		info.post = PostInfo(art, replart, info.group.name);
		info.thread = ThreadInfo(m_ctrl.getThread(art.groups[escapeGroup(grp.name)].threadId), m_ctrl, 0, grp.name);

		res.render!("vibenews.web.view_post.dt", req, info);
	}

	void redirectShowPost(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.redirect((Path(req.path)~"../../../post/"~req.params["post"]).toString(), HTTPStatus.movedPermanently);
	}

	void showPostArticle(HTTPServerRequest req, HTTPServerResponse res)
	{
		string groupname;
		if( auto pg = "group" in req.query ) groupname = *pg;
		else groupname = req.form["group"];
		auto grp = m_ctrl.getGroupByName(groupname);

		if( !enforceAuth(req, res, grp, true) )
			return;

		static struct Info5 {
			VibeNewsSettings settings;
			GroupInfo group;
			bool loggedIn = false;
			string threadSubject;
			string error;
			string name;
			string email;
			string subject;
			string message;
		}

		Info5 info;
		info.settings = m_settings;

		if( req.session ){
			if( req.session.isKeySet("userEmail") ){
				info.loggedIn = true;
				info.name = req.session.get!string("userFullName");
				info.email = req.session.get!string("userEmail");
			} else {
				info.name = req.session.get!string("lastUsedName");
				info.email = req.session.get!string("lastUsedEmail");
			}
		}

		if( "reply-to" in req.query ){
			auto repartnum = req.query["reply-to"].to!long();
			auto repart = m_ctrl.getArticle(grp.name, repartnum);
			info.subject = repart.subject;
			if( !info.subject.startsWith("Re:") ) info.subject = "Re: " ~ info.subject;
			info.message = "On "~repart.getHeader("Date")~", "~PosterInfo(repart.getHeader("From")).name~" wrote:\r\n";
			info.message ~= map!(ln => ln.startsWith(">") ? ">" ~ ln : "> " ~ ln)(splitLines(decodeMessage(repart))).join("\r\n");
			info.message ~= "\r\n\r\n";
		}
		if ("thread" in req.query) {
			info.threadSubject = m_ctrl.getArticle(grp.name, req.query["thread"].to!long).subject;
		}
		info.group = GroupInfo(grp, m_ctrl);

		// recover old values if showPostArticle was called because of an error
		if( auto per = "error" in req.params ) info.error = *per;
		if( auto pnm = "name" in req.form ) info.name = *pnm;
		if( auto pem = "email" in req.form ) info.email = *pem;
		if( auto psj = "subject" in req.form ) info.subject = *psj;
		if( auto pmg = "message" in req.form ) info.message = *pmg;

		res.render!("vibenews.web.reply.dt", req, info);
	}

	void markupArticle(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto msg = req.form["message"];
		validateString(msg, 0, 128*1024, "The message body");
		res.writeBody(filterMarkdown(msg, MarkdownFlags.forumDefault), "text/html");
	}

	void postArticle(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.form["group"]);

		User.ID user_id;
		if( !enforceAuth(req, res, grp, true, &user_id) )
			return;

		bool loggedin = req.session && req.session.isKeySet("userEmail");
		string email = loggedin ? req.session.get!string("userEmail") : req.form["email"].strip();
		string name = loggedin ? req.session.get!string("userFullName") : req.form["name"].strip();
		string subject = req.form["subject"].strip();
		string message = req.form["message"];

		try {
			validateEmail(email);
			validateString(name, 3, 64, "The poster name");
			validateString(subject, 1, 128, "The message subject");
			validateString(message, 0, 128*1024, "The message body");

			if( !loggedin ){
				enforce(!m_ctrl.isEmailRegistered(email), "The email address is already in use by a registered account. Please log in to use it.");
			}
		} catch(Exception e){
			req.params["error"] = e.msg;
			showPostArticle(req, res);
			return;
		}

		Article art;
		art._id = BsonObjectID.generate();
		art.id = "<"~art._id.toString()~"@"~m_settings.hostName~">";
		art.addHeader("Subject", subject);
		art.addHeader("From", "\""~name~"\" <"~email~">");
		art.addHeader("Newsgroups", grp.name);
		art.addHeader("Date", Clock.currTime(UTC()).toRFC822DateTimeString());
		art.addHeader("User-Agent", "VibeNews Web");
		art.addHeader("Content-Type", "text/x-markdown; charset=UTF-8; format=flowed");
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

		try m_ctrl.postArticle(art, user_id);
		catch( Exception e ){
			req.params["error"] = e.msg;
			showPostArticle(req, res);
			return;
		}

		if( !req.session ) req.session = res.startSession();
		req.session.set("lastUsedName", name.idup);
		req.session.set("lastUsedEmail", email.idup);

		redirectToThreadPost(res, Path(req.path).parentPath.toString(), grp.name, art.groups[escapeGroup(grp.name)].articleNumber, art.groups[escapeGroup(grp.name)].threadId);
	}

	void redirectToThreadPost(HTTPServerResponse res, string groups_path, string groupname, long article_number, BsonObjectID thread_id = BsonObjectID(), HTTPStatus redirect_status_code = HTTPStatus.Found)
	{
		if( thread_id == BsonObjectID() ){
			auto refs = m_ctrl.getArticleGroupRefs(groupname, article_number);
			thread_id = refs[escapeGroup(groupname)].threadId;
		}
		auto thr = m_ctrl.getThread(thread_id);
		auto first_art_refs = m_ctrl.getArticleGroupRefs(thr.firstArticleId);
		auto first_art_num = first_art_refs[escapeGroup(groupname)].articleNumber;
		auto url = groups_path~groupname~"/thread/"~first_art_num.to!string()~"/";
		if( article_number != first_art_num ){
			auto index = m_ctrl.getThreadArticleIndex(thr._id, article_number, groupname);
			auto page = index / m_postsPerPage + 1;
			if( page > 1 ) url ~= "?page="~to!string(page);
			url ~= "#post-"~to!string(article_number);
		}
		res.redirect(url, redirect_status_code);
	}

	bool enforceAuth(HTTPServerRequest req, HTTPServerResponse res, ref Group grp, bool read_write, User.ID* user_id = null)
	{
		if( user_id ) *user_id = User.ID.init;
		User.ID uid;
		string[] authTags;
		if( req.session && req.session.isKeySet("userEmail") ){
			auto usr = m_ctrl.getUserByEmail(req.session.get!string("userEmail"));
			foreach (g; usr.groups)
				authTags ~= m_ctrl.getAuthGroup(g).name;
			if( user_id ) *user_id = usr.id;
			uid = usr.id;
		}

		if( grp.readOnlyAuthTags.empty && grp.readWriteAuthTags.empty )
			return true;

		auto alltags = grp.readWriteAuthTags;
		if( !read_write ) alltags ~= grp.readOnlyAuthTags;

		bool found = false;
		foreach( t; alltags )
			if( authTags.canFind(t) ){
				found = true;
				break;
			}
		if( !found ){
			if (uid == User.ID.init) {
				res.redirect("/login?redirect="~urlEncode(req.requestURL));
				return false;
			} else {
				throw new HTTPStatusException(HTTPStatus.forbidden, "Group is protected.");
			}
		}
		return true;
	}
}

struct GroupInfo {
	this(Group grp, Controller ctrl)
	{
		try {
			lastPostNumber = grp.maxArticleNumber;
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
	long lastPostNumber;
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
			firstPost.subject = firstpost.subject;
			
			auto lastpost = ctrl.getArticle(thr.lastArticleId);
			lastPost.poster = PosterInfo(lastpost.getHeader("From"));
			lastPost.date = lastpost.getHeader("Date");//.parseRFC822DateTimeString();
			lastPost.number = lastpost.groups[escapeGroup(groupname)].articleNumber;
			lastPost.subject = lastpost.subject;
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
		subject = art.subject;
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
		if( str.length ){
			decodeEmailAddressHeader(str, name, email);
		}
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
