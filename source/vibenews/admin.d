module vibenews.admin;

import vibenews.db;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.data.bson;
import vibe.http.router;
import vibe.http.server;

import std.exception;


void startAdminInterface()
{
	auto settings = new HttpServerSettings;
	settings.port = 9009;
	settings.bindAddresses = ["127.0.0.1"];

	auto router = new UrlRouter;
	router.get("/", &showAdminPanel);
	router.post("/groups/create", &createGroup);
	router.get("/groups/:groupname/show", &showGroup);
	router.post("/groups/:groupname/update", &updateGroup);

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
	logInfo("hello");
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