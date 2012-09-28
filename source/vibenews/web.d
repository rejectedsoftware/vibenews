module vibenews.web;

import vibenews.db;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.data.bson;
import vibe.http.router;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.utils.string;

import std.conv;
import std.datetime;
import std.exception;


class WebInterface {
	private {
		Controller m_ctrl;
		string m_title = "My Forum";
	}

	this(Controller ctrl)
	{
		m_ctrl = ctrl;

		auto settings = new HttpServerSettings;
		settings.port = 8009;
		settings.bindAddresses = ["127.0.0.1"];

		auto router = new UrlRouter;
		router.get("/", &showIndex);
		router.get("/groups/:group/", &showGroup);
		router.get("/groups/:group/:thread/", &showThread);
		router.get("/groups/:group/:thread/:post/reply", &showReply);
		router.post("/groups/:group/:thread/:post/reply", &postReply);
		router.get("*", serveStaticFiles("public"));

		listenHttp(settings, router);
	}

	void showIndex(HttpServerRequest req, HttpServerResponse res)
	{
		static struct Info1 {
			string title;
			Category[] groupCategories;
		}
		Info1 info;
		info.title = m_title;

		Category cat;
		cat.title = "All";
		m_ctrl.enumerateGroups((idx, grp){
			GroupInfo gi;
			try {
				auto lastpost = m_ctrl.getArticle(grp.name, grp.maxArticleNumber);
				gi.lastPoster.name = lastpost.getHeader("From");
				//gi.lastPostDate = lastpost.getHeader("Date");
			} catch( Exception ){}

			gi.name = grp.name;
			gi.description = grp.description;
			gi.numberOfPosts = grp.articleCount;
			gi.numberOfTopics = m_ctrl.getThreadCount(grp._id);
			cat.groups ~= gi;
		});
		info.groupCategories ~= cat;

		res.renderCompat!("vibenews.web.index.dt",
			HttpServerRequest, "req",
			Info1*, "info")(Variant(req), Variant(&info));
	}

	void showGroup(HttpServerRequest req, HttpServerResponse res)
	{
		static struct Info2 {
			string title;
			GroupInfo group;
		}
		Info2 info;
		info.title = m_title;

		res.renderCompat!("vibenews.web.view_group.dt",
			HttpServerRequest, "req",
			Info2*, "info")(Variant(req), Variant(&info));
	}

	void showThread(HttpServerRequest req, HttpServerResponse res)
	{
		static struct Info3 {
			string title;
			PostInfo[] posts;
		}
		Info3 info;

		res.renderCompat!("vibenews.web.view_thread.dt",
			HttpServerRequest, "req",
			Info3*, "info")(Variant(req), Variant(&info));
	}

	void showReply(HttpServerRequest req, HttpServerResponse res)
	{
		static struct Info4 {
			string title;
		}
		Info4 info;

		res.renderCompat!("vibenews.web.reply.dt",
			HttpServerRequest, "req",
			Info4*, "info")(Variant(req), Variant(&info));
	}

	void postReply(HttpServerRequest req, HttpServerResponse res)
	{
		auto groupname = req.params["group"];
		auto threadid = req.params["thread"];

		res.redirect(formatString("/%s/%s/", groupname, threadid));
	}
}

struct GroupInfo {
	string name;
	string description;
	long numberOfTopics;
	long numberOfPosts;
	PosterInfo lastPoster;
	SysTime lastPostDate;
	ThreadInfo[] threads;
}

struct ThreadInfo {
	BsonObjectID id;
	string subject;
	PosterInfo firstPoster;
	SysTime firstPostDate;
	PosterInfo lastPoster;
	SysTime lastPostDate;
	size_t pageCount;
	size_t postCount;
}

struct PostInfo {
	BsonObjectID id;
	string subject;
	PosterInfo poster;
	PosterInfo repliedToPoster;
	SysTime date;
	string message;
}

struct PosterInfo {
	string name;
	string email;
}

struct Category {
	string title;
	GroupInfo[] groups;
}
