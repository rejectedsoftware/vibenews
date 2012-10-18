module vibenews.web;

import vibenews.db;
import vibenews.vibenews : g_hostname;

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

import std.algorithm : filter, map, sort;
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
		string m_title;
	}

	this(Controller ctrl, string title)
	{
		m_ctrl = ctrl;
		m_title = title;

		auto settings = new HttpServerSettings;
		settings.port = 8009;
		settings.bindAddresses = ["127.0.0.1"];
		settings.sessionStore = new MemorySessionStore;

		auto router = new UrlRouter;
		router.get("/", &showIndex);
		router.post("/markup", &markupArticle);
		router.get("/groups/:group/", &showGroup);
		router.get("/groups/:group/post", &showPostArticle);
		router.post("/groups/:group/post", &postArticle);
		router.get("/groups/:group/thread/:thread/", &showThread);
		router.get("/groups/:group/thread/:thread/reply", &showPostArticle);
		router.post("/groups/:group/thread/:thread/reply", &postArticle);
		router.get("/groups/:group/post/:post", &showPost);
		router.get("/groups/:group/thread/:thread/:post", &showPost); // deprecated
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
		info.title = m_title;

		Group[] groups;
		m_ctrl.enumerateGroups((idx, grp){
			if( grp.readOnlyAuthTags.length || grp.readWriteAuthTags.length )
				return;
			groups ~= grp;
		});
		m_ctrl.enumerateGroupCategories((idx, cat){ info.categories ~= Category(cat, groups, m_ctrl); });

		if( !info.categories.length ) info.categories ~= Category("All", groups, m_ctrl);

		info.categories.sort!"a.index < b.index"();

		res.renderCompat!("vibenews.web.index.dt",
			HttpServerRequest, "req",
			Info1*, "info")(Variant(req), Variant(&info));
	}

	void showGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);
		if( grp.readOnlyAuthTags.length || grp.readWriteAuthTags.length )
			throw new HttpStatusException(HttpStatus.Forbidden, "Group is protected.");

		static struct Info2 {
			string title;
			GroupInfo group;
			ThreadInfo[] threads;
			size_t page = 0;
			size_t pageSize = 10;
			size_t pageCount;
		}
		Info2 info;
		info.title = m_title;
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
		if( grp.readOnlyAuthTags.length || grp.readWriteAuthTags.length )
			throw new HttpStatusException(HttpStatus.Forbidden, "Group is protected.");

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

		info.title = m_title;
		info.hostName = g_hostname;
		auto threadnum = req.params["thread"].to!long();
		if( auto ps = "page" in req.query ) info.page = to!size_t(*ps) - 1;
		info.thread = ThreadInfo(m_ctrl.getThreadForFirstArticle(grp.name, threadnum), m_ctrl, info.pageSize, grp.name);
		info.group = GroupInfo(grp, m_ctrl);
		info.postCount = cast(size_t)m_ctrl.getThreadPostCount(info.thread.id, grp.name);
		info.pageCount = (info.postCount + info.pageSize-1) / info.pageSize;

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
		if( grp.readOnlyAuthTags.length || grp.readWriteAuthTags.length )
			throw new HttpStatusException(HttpStatus.Forbidden, "Group is protected.");

		static struct Info4 {
			string title;
			string hostName;
			GroupInfo group;
			PostInfo post;
			ThreadInfo thread;
		}
		Info4 info;

		auto postnum = req.params["post"].to!long();

		info.title = m_title;
		info.hostName = g_hostname;
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

	void showPostArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto grp = m_ctrl.getGroupByName(req.params["group"]);
		if( grp.readOnlyAuthTags.length || grp.readWriteAuthTags.length )
			throw new HttpStatusException(HttpStatus.Forbidden, "Group is protected.");

		static struct Info5 {
			string title;
			GroupInfo group;
			string name;
			string email;
			string subject;
			string message;
		}
		Info5 info;

		if( req.session ){
			info.name = req.session["name"];
			info.email = req.session["email"];
		}

		if( "post" in req.query ){
			auto repartnum = req.query["post"].to!long();
			auto repart = m_ctrl.getArticle(grp.name, repartnum);
			info.subject = repart.getHeader("Subject");
			if( !info.subject.startsWith("Re:") ) info.subject = "Re: " ~ info.subject;
			info.message = "On "~repart.getHeader("Date")~", "~PosterInfo(repart.getHeader("From")).name~" wrote:\r\n";
			info.message ~= map!(ln => ln.startsWith(">") ? ">" ~ ln : "> " ~ ln)(splitLines(decodeMessage(repart))).join("\r\n");
			info.message ~= "\r\n\r\n";
		}
		info.title = m_title;
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
		auto grp = m_ctrl.getGroupByName(req.params["group"]);
		if( grp.readOnlyAuthTags.length || grp.readWriteAuthTags.length )
			throw new HttpStatusException(HttpStatus.Forbidden, "Group is protected.");

		validateEmail(req.form["email"]);
		validateString(req.form["name"], 3, 64, "The poster name");
		validateString(req.form["subject"], 1, 128, "The message subject");
		validateString(req.form["message"], 0, 128*1024, "The message body");

		Article art;
		art._id = BsonObjectID.generate();
		art.id = "<"~art._id.toString()~"@"~g_hostname~">";
		art.addHeader("Subject", req.form["subject"]);
		art.addHeader("From", "\""~req.form["name"]~"\" <"~req.form["email"]~">");
		art.addHeader("Newsgroups", grp.name);
		art.addHeader("Date", Clock.currTime().toRFC822DateTimeString());
		art.addHeader("User-Agent", "VibeNews Web");
		art.addHeader("Content-Type", "text/plain; charset=UTF-8; format=flowed");

		if( "article" in req.form ){
			auto repartnum = req.form["article"].to!long();
			auto repart = m_ctrl.getArticle(grp.name, repartnum, false);
			auto refs = repart.getHeader("References");
			if( refs.length ) refs ~= " ";
			refs ~= repart.id;
			art.addHeader("In-Reply-To", repart.id);
			art.addHeader("References", refs);
		}

		art.peerAddress = req.peer;
		art.message = cast(ubyte[])(req.form["message"] ~ "\r\n");

		m_ctrl.postArticle(art);

		auto thr = m_ctrl.getThread(art.groups[escapeGroup(grp.name)].threadId);
		auto refs = m_ctrl.getArticleGruopRefs(thr.firstArticleId);

		Session session = req.session;
		if( !session ) session = res.startSession();
		session["name"] = req.form["name"].idup;
		session["email"] = req.form["email"].idup;
		res.redirect(formatString("/groups/%s/thread/%s/", urlEncode(grp.name), refs[escapeGroup(grp.name)].articleNumber));
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
	switch( art.getHeader("Content-Transfer-Encoding") ){
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
						dec.popFront()
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
