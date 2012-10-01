module vibenews.admin;

import vibenews.db;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.data.bson;
import vibe.http.router;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.textfilter.urlencode;

import std.algorithm : map;
import std.array;
import std.conv;
import std.exception;
import std.string;


class AdminInterface {
	private {
		Controller m_ctrl;
	}

	this(Controller ctrl)
	{
		m_ctrl = ctrl;

		auto settings = new HttpServerSettings;
		settings.port = 9009;
		settings.bindAddresses = ["127.0.0.1"];

		auto router = new UrlRouter;
		router.get("/", &showAdminPanel);
		router.post("/groups/create", &createGroup);
		router.post("/groups/repair-numbers", &repairGroupNumbers);
		router.post("/groups/repair-threads", &repairGroupThreads);
		router.get("/groups/:groupname/show", &showGroup);
		router.post("/groups/:groupname/update", &updateGroup);
		router.post("/groups/:groupname/purge", &purgeGroup);
		router.get("/groups/:groupname/articles", &showArticles);
		router.post("/articles/:articleid/activate", &activateArticle);
		router.post("/articles/:articleid/deactivate", &deactivateArticle);
		router.get("*", serveStaticFiles("public"));

		listenHttp(settings, router);
	}

	void showAdminPanel(HttpServerRequest req, HttpServerResponse res)
	{
		Group[] groups;
		m_ctrl.enumerateGroups((idx, group){
				groups ~= group;
			}, true);
		res.renderCompat!("vibenews.admin.dt",
				HttpServerRequest, "req",
				Group[], "groups"
			)(Variant(req), Variant(groups));
	}

	void showGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto group = m_ctrl.getGroupByName(req.params["groupname"], true);
		res.renderCompat!("vibenews.editgroup.dt",
				HttpServerRequest, "req",
				Group*, "group"
			)(Variant(req), Variant(&group));
	}

	void createGroup(HttpServerRequest req, HttpServerResponse res)
	{
		enforce(!m_ctrl.groupExists(req.form["name"], true), "A group with the specified name already exists");
	
		Group group;
		group._id = BsonObjectID.generate();
		group.active = false;
		group.name = req.form["name"];
		group.description = req.form["description"];
		m_ctrl.addGroup(group);

		res.redirect("/groups/"~urlEncode(group.name)~"/show");
	}

	void updateGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto group = m_ctrl.getGroupByName(req.params["groupname"], true);
		group.description = req.form["description"];
		group.active = ("active" in req.form) !is null;
		group.readOnlyAuthTags = req.form["roauthtags"].split(",").map!(s => strip(s))().array();
		group.readWriteAuthTags = req.form["rwauthtags"].split(",").map!(s => strip(s))().array();
		m_ctrl.updateGroup(group);
		res.redirect("/groups/"~urlEncode(group.name)~"/show");
	}

	void purgeGroup(HttpServerRequest req, HttpServerResponse res)
	{
		m_ctrl.purgeGroup(req.params["groupname"]);
		res.redirect("/groups/"~req.params["groupname"]~"/show");
	}

	void repairGroupNumbers(HttpServerRequest req, HttpServerResponse res)
	{
		m_ctrl.repairGroupNumbers();
		res.redirect("/");
	}

	void repairGroupThreads(HttpServerRequest req, HttpServerResponse res)
	{
		m_ctrl.repairThreads();
		res.redirect("/");
	}

	void showArticles(HttpServerRequest req, HttpServerResponse res)
	{
		struct Info {
			enum articlesPerPage = 20;
			string groupname;
			int page;
			Article[] articles;
			int articleCount;
			int pageCount;
		}
		Info info;
		info.groupname = req.params["groupname"];
		info.page = ("page" in req.query) ? to!int(req.query["page"])-1 : 0;
		m_ctrl.enumerateAllArticles(info.groupname, info.page*info.articlesPerPage, info.articlesPerPage, (ref art){ info.articles ~= art; });
		info.articleCount = cast(int)m_ctrl.getAllArticlesCount(info.groupname);
		info.pageCount = (info.articleCount-1)/info.articlesPerPage + 1;

		res.renderCompat!("vibenews.listarticles.dt",
			HttpServerRequest, "req",
			Info*, "info")(Variant(req), Variant(&info));
	}

	void activateArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		m_ctrl.activateArticle(artid);
		res.redirect("/groups/"~req.form["groupname"]~"/articles?page="~req.form["page"]);
	}

	void deactivateArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		m_ctrl.deactivateArticle(artid);
		res.redirect("/groups/"~req.form["groupname"]~"/articles?page="~req.form["page"]);
	}
}
