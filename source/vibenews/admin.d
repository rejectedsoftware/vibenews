module vibenews.admin;

import vibenews.db;
import vibenews.vibenews;

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

	this(Controller ctrl, VibeNewsSettings vnsettings)
	{
		m_ctrl = ctrl;

		auto settings = new HttpServerSettings;
		settings.port = vnsettings.adminPort;
		settings.bindAddresses = ["127.0.0.1"];

		auto router = new UrlRouter;
		router.get("/", &showAdminPanel);
		router.post("/categories/create", &createGroupCategory);
		router.get("/categories/:category/show", &showGroupCategory);
		router.post("/categories/:category/update", &updateGroupCategory);
		router.post("/categories/:category/delete", &deleteGroupCategory);
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
		GroupCategory[] categories;
		m_ctrl.enumerateGroups((idx, group){ groups ~= group; }, true);
		m_ctrl.enumerateGroupCategories((idx, cat){ categories ~= cat; });
		res.renderCompat!("vibenews.admin.index.dt",
				HttpServerRequest, "req",
				Group[], "groups",
				GroupCategory[], "categories"
			)(Variant(req), Variant(groups), Variant(categories));
	}

	void showGroupCategory(HttpServerRequest req, HttpServerResponse res)
	{
		auto category = m_ctrl.getGroupCategory(BsonObjectID.fromString(req.params["category"]));
		Group[] groups;
		m_ctrl.enumerateGroups((idx, grp){ groups ~= grp; });
		res.renderCompat!("vibenews.admin.editcategory.dt",
			HttpServerRequest, "req",
			GroupCategory*, "category",
			Group[], "groups")(Variant(req), Variant(&category), Variant(groups));
	}

	void updateGroupCategory(HttpServerRequest req, HttpServerResponse res)
	{
		auto id = BsonObjectID.fromString(req.params["category"]);
		auto caption = req.form["caption"];
		auto index = req.form["index"].to!int();
		BsonObjectID[] groups;
		m_ctrl.enumerateGroups((idx, grp){ if( grp._id.toString() in req.form ) groups ~= grp._id; });
		m_ctrl.updateGroupCategory(id, caption, index, groups);
		res.redirect("/categories/"~id.toString()~"/show");
	}

	void deleteGroupCategory(HttpServerRequest req, HttpServerResponse res)
	{
		auto id = BsonObjectID.fromString(req.params["category"]);
		m_ctrl.deleteGroupCategory(id);
		res.redirect("/");
	}

	void showGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto group = m_ctrl.getGroupByName(req.params["groupname"], true);
		res.renderCompat!("vibenews.admin.editgroup.dt",
				HttpServerRequest, "req",
				Group*, "group"
			)(Variant(req), Variant(&group));
	}

	void createGroupCategory(HttpServerRequest req, HttpServerResponse res)
	{
		auto id = m_ctrl.createGroupCategory(req.form["caption"], req.form["index"].to!int());
		res.redirect("/categories/"~id.toString()~"/show");
	}

	void createGroup(HttpServerRequest req, HttpServerResponse res)
	{
		enforce(!m_ctrl.groupExists(req.form["name"], true), "A group with the specified name already exists");
	
		Group group;
		group._id = BsonObjectID.generate();
		group.active = false;
		group.name = req.form["name"];
		group.caption = req.form["caption"];
		m_ctrl.addGroup(group);

		res.redirect("/groups/"~urlEncode(group.name)~"/show");
	}

	void updateGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto group = m_ctrl.getGroupByName(req.params["groupname"], true);
		group.caption = req.form["caption"];
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
		m_ctrl.enumerateAllArticlesBackwards(info.groupname, info.page*info.articlesPerPage, info.articlesPerPage, (ref art){ info.articles ~= art; });
		info.articleCount = cast(int)m_ctrl.getAllArticlesCount(info.groupname);
		info.pageCount = (info.articleCount-1)/info.articlesPerPage + 1;

		res.renderCompat!("vibenews.admin.listarticles.dt",
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
