module vibenews.admin;

import vibenews.db;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.data.bson;
import vibe.http.router;
import vibe.http.server;
import vibe.http.fileserver;

import std.conv;
import std.exception;

class AdminInterface {
	this()
	{
		auto settings = new HttpServerSettings;
		settings.port = 9009;
		settings.bindAddresses = ["127.0.0.1"];

		auto router = new UrlRouter;
		router.get("/", &showAdminPanel);
		router.post("/groups/create", &createGroup);
		router.post("/groups/repair", &repairGroups);
		router.get("/groups/:groupname/show", &showGroup);
		router.post("/groups/:groupname/update", &updateGroup);
		router.get("/groups/:groupname/articles", &showArticles);
		router.post("/articles/:articleid/activate", &activateArticle);
		router.post("/articles/:articleid/deactivate", &deactivateArticle);
		router.get("*", serveStaticFiles("public"));

		listenHttp(settings, router);
	}

	void showAdminPanel(HttpServerRequest req, HttpServerResponse res)
	{
		Group[] groups;
		enumerateGroups((idx, group){
				groups ~= group;
			});
		res.renderCompat!("vibenews.admin.dt",
				HttpServerRequest, "req",
				Group[], "groups"
			)(Variant(req), Variant(groups));
	}

	void showGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto group = getGroupByName(req.params["groupname"]);
		res.renderCompat!("vibenews.editgroup.dt",
				HttpServerRequest, "req",
				Group*, "group"
			)(Variant(req), Variant(&group));
	}

	void createGroup(HttpServerRequest req, HttpServerResponse res)
	{
		enforce(!groupExists(req.form["name"]), "A group with the specified name already exists");
		enforce(req.form["password"] == req.form["passwordConfirmation"]);

		Group group;
		group._id = BsonObjectID.generate();
		group.name = req.form["name"];
		group.description = req.form["description"];
		group.username = req.form["username"];
		if( req.form["password"].length > 0 )
			group.passwordHash = generateSimplePasswordHash(req.form["password"]);

		addGroup(group);

		res.redirect("/");
	}

	void updateGroup(HttpServerRequest req, HttpServerResponse res)
	{
		auto group = getGroupByName(req.params["groupname"]);
		group.description = req.form["description"];
		group.username = req.form["username"];
		group.active = ("active" in req.form) !is null;
		enforce(req.form["password"] == req.form["passwordConfirmation"]);
		if( req.form["password"].length > 0 )
			group.passwordHash = generateSimplePasswordHash(req.form["password"]);
		vibenews.db.updateGroup(group);
		res.redirect("/");
	}

	void repairGroups(HttpServerRequest req, HttpServerResponse res)
	{
		repairGroupNumbers();
		res.redirect("/");
	}

	void showArticles(HttpServerRequest req, HttpServerResponse res)
	{
		struct Info {
			enum articlesPerPage = 100;
			string groupname;
			int page;
			Article[] articles;
			int articleCount;
			int pageCount;
		}
		Info info;
		info.groupname = req.params["groupname"];
		info.page = ("page" in req.query) ? to!int(req.query["page"])-1 : 0;
		enumerateAllArticles(info.groupname, info.page*info.articlesPerPage, info.articlesPerPage, (ref art){ info.articles ~= art; });
		info.articleCount = cast(int)getAllArticlesCount(info.groupname);
		info.pageCount = (info.articleCount-1)/info.articlesPerPage + 1;

		res.renderCompat!("vibenews.listarticles.dt",
			HttpServerRequest, "req",
			Info*, "info")(Variant(req), Variant(&info));
	}

	void activateArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		.activateArticle(artid);
		res.redirect("/groups/"~req.form["groupname"]~"/articles?page="~req.form["page"]);
	}

	void deactivateArticle(HttpServerRequest req, HttpServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		.deactivateArticle(artid);
		res.redirect("/groups/"~req.form["groupname"]~"/articles?page="~req.form["page"]);
	}
}
