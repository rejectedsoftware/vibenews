/**
	(module summary)

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.admin;

import vibenews.controller;
import vibenews.vibenews;

import userman.db.controller : User;
static import userman.db.controller;

import vibe.core.log;
import vibe.data.bson;
import vibe.http.router;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.textfilter.urlencode;
import vibe.utils.validation;

import std.algorithm : map;
import std.array;
import std.conv;
import std.exception;
import std.string;
import std.variant;

class AdminInterface {
	private {
		Controller m_ctrl;
	}

	enum articlesPerPage = 20;

	this(Controller ctrl)
	{
		m_ctrl = ctrl;
	}

	void listen()
	{
		auto vnsettings = m_ctrl.settings;

		auto settings = new HTTPServerSettings;
		settings.port = vnsettings.adminPort;
		settings.bindAddresses = vnsettings.adminBindAddresses;

		auto router = new URLRouter;
		register(router);

		listenHTTP(settings, router);
	}

	void register(URLRouter router)
	{
		router.get("/", &showAdminPanel);
		router.post("/categories/create", &createGroupCategory);
		router.get("/categories/:category/show", &showGroupCategory);
		router.post("/categories/:category/update", &updateGroupCategory);
		router.post("/categories/:category/delete", &deleteGroupCategory);
		router.post("/reclassify_spam", &reclassifySpam);
		router.post("/groups/create", &createGroup);
		router.post("/groups/repair-numbers", &repairGroupNumbers);
		router.post("/groups/repair-threads", &repairGroupThreads);
		router.get("/groups/:groupname/show", &showGroup);
		router.post("/groups/:groupname/update", &updateGroup);
		router.post("/groups/:groupname/purge", &purgeGroup);
		router.get("/groups/:groupname/articles", &showArticles);
		router.post("/groups/:groupname/articles/mark_page_as_spam", &markPageAsSpam);
		router.post("/articles/:articleid/activate", &activateArticle);
		router.post("/articles/:articleid/deactivate", &deactivateArticle);
		router.post("/articles/:articleid/mark_ham", &markAsHam);
		router.post("/articles/:articleid/mark_spam", &markAsSpam);
		router.get("/users/", &showListUsers);
		router.get("/users/:user/", &showUser);
		router.post("/users/:user/update", &updateUser);
		router.post("/users/:user/delete", &deleteUser);
		router.post("/users/deleteOrphaned", &postDeleteOrphanedUsers);
		router.get("*", serveStaticFiles("public"));
	}

	void showAdminPanel(HTTPServerRequest req, HTTPServerResponse res)
	{
		struct Info {
			VibeNewsSettings settings;
		}
		auto info = Info(m_ctrl.settings);

		Group[] groups;
		GroupCategory[] categories;
		m_ctrl.enumerateGroups((idx, group){ groups ~= group; }, true);
		m_ctrl.enumerateGroupCategories((idx, cat){ categories ~= cat; });
		res.render!("vibenews.admin.index.dt", req, info, groups, categories);
	}

	void showGroupCategory(HTTPServerRequest req, HTTPServerResponse res)
	{
		struct Info {
			VibeNewsSettings settings;
		}
		auto info = Info(m_ctrl.settings);

		auto category = m_ctrl.getGroupCategory(BsonObjectID.fromString(req.params["category"]));
		Group[] groups;
		m_ctrl.enumerateGroups((idx, grp){ groups ~= grp; });
		res.render!("vibenews.admin.editcategory.dt", req, info, category, groups);
	}

	void updateGroupCategory(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto id = BsonObjectID.fromString(req.params["category"]);
		auto caption = req.form["caption"];
		auto index = req.form["index"].to!int();
		BsonObjectID[] groups;
		m_ctrl.enumerateGroups((idx, grp){ if( grp._id.toString() in req.form ) groups ~= grp._id; });
		m_ctrl.updateGroupCategory(id, caption, index, groups);
		res.redirect("/categories/"~id.toString()~"/show");
	}

	void deleteGroupCategory(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto id = BsonObjectID.fromString(req.params["category"]);
		m_ctrl.deleteGroupCategory(id);
		res.redirect("/");
	}

	void showGroup(HTTPServerRequest req, HTTPServerResponse res)
	{
		struct Info {
			VibeNewsSettings settings;
		}
		auto info = Info(m_ctrl.settings);

		auto group = m_ctrl.getGroupByName(req.params["groupname"], true);
		res.render!("vibenews.admin.editgroup.dt", req, info, group);
	}

	void createGroupCategory(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto id = m_ctrl.createGroupCategory(req.form["caption"], req.form["index"].to!int());
		res.redirect("/categories/"~id.toString()~"/show");
	}

	void reclassifySpam(HTTPServerRequest req, HTTPServerResponse res)
	{
		m_ctrl.reclassifySpam();
		res.redirect("/");
	}

	void createGroup(HTTPServerRequest req, HTTPServerResponse res)
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

	void updateGroup(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto group = m_ctrl.getGroupByName(req.params["groupname"], true);
		group.caption = req.form["caption"];
		group.description = req.form["description"];
		group.active = ("active" in req.form) !is null;
		group.readOnlyAuthTags = req.form["roauthtags"].split(",").map!(s => authGroupPrefix ~ strip(s))().array();
		group.readWriteAuthTags = req.form["rwauthtags"].split(",").map!(s => authGroupPrefix ~ strip(s))().array();
		m_ctrl.updateGroup(group);
		res.redirect("/groups/"~urlEncode(group.name)~"/show");
	}

	void purgeGroup(HTTPServerRequest req, HTTPServerResponse res)
	{
		m_ctrl.purgeGroup(req.params["groupname"]);
		res.redirect("/groups/"~req.params["groupname"]~"/show");
	}

	void repairGroupNumbers(HTTPServerRequest req, HTTPServerResponse res)
	{
		m_ctrl.repairGroupNumbers();
		res.redirect("/");
	}

	void repairGroupThreads(HTTPServerRequest req, HTTPServerResponse res)
	{
		m_ctrl.repairThreads();
		res.redirect("/");
	}

	void showArticles(HTTPServerRequest req, HTTPServerResponse res)
	{
		struct Info {
			VibeNewsSettings settings;
			string groupname;
			int page;
			Article[] articles;
			int articleCount;
			enum articlesPerPage = AdminInterface.articlesPerPage;
 			int pageCount;
			bool onlyActive;
		}

		Info info;
		info.settings = m_ctrl.settings;
		info.groupname = req.params["groupname"];
		info.page = ("page" in req.query) ? to!int(req.query["page"])-1 : 0;
		info.onlyActive = req.query.get("only_active", "") == "1";
		if (info.onlyActive) {
			m_ctrl.enumerateActiveArticlesBackwards(info.groupname, info.page*info.articlesPerPage, info.articlesPerPage, (ref art){ info.articles ~= art; });
			info.articleCount = cast(int)m_ctrl.getActiveArticlesCount(info.groupname);
		} else {
			m_ctrl.enumerateAllArticlesBackwards(info.groupname, info.page*info.articlesPerPage, info.articlesPerPage, (ref art){ info.articles ~= art; });
			info.articleCount = cast(int)m_ctrl.getAllArticlesCount(info.groupname);
		}
		info.pageCount = (info.articleCount-1)/info.articlesPerPage + 1;

		res.render!("vibenews.admin.listarticles.dt", req, info);
	}

	void activateArticle(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		m_ctrl.activateArticle(artid);
		redirectBackToArticles(req, res);
	}

	void deactivateArticle(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		m_ctrl.deactivateArticle(artid);
		redirectBackToArticles(req, res);
	}

	void markAsSpam(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		m_ctrl.markAsSpam(artid, true);
		redirectBackToArticles(req, res);
	}

	void markAsHam(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto artid = BsonObjectID.fromString(req.params["articleid"]);
		m_ctrl.markAsSpam(artid, false);
		redirectBackToArticles(req, res);
	}

	void markPageAsSpam(HTTPServerRequest req, HTTPServerResponse res)
	{
		string groupname = req.params["groupname"];
		int page = req.form["page"].to!int-1;
		bool onlyactive = req.form.get("only_active", "") == "1";
		void handleArticle(ref Article art)
		@trusted {
			m_ctrl.markAsSpam(art._id, true);
		}
		if (onlyactive)
			m_ctrl.enumerateActiveArticlesBackwards(groupname, page*articlesPerPage, articlesPerPage, &handleArticle);
		else
			m_ctrl.enumerateAllArticlesBackwards(groupname, page*articlesPerPage, articlesPerPage, &handleArticle);
		redirectBackToArticles(req, res);
	}

	private void redirectBackToArticles(HTTPServerRequest req, HTTPServerResponse res)
	{
		string suff = req.form.get("only_active", "") == "1" ? "&only_active=1" : null;
		auto group = "groupname" in req.params ? req.params["groupname"] : req.form["groupname"];
		res.redirect("/groups/"~group~"/articles?page="~req.form["page"]~suff);
	}

	void showListUsers(HTTPServerRequest req, HTTPServerResponse res)
	{
		struct Info {
			VibeNewsSettings settings;
			enum itemsPerPage = 20;
			UserInfo[] users;
			int page;
			int itemCount;
			int pageCount;
		}

		Info info;
		info.settings = m_ctrl.settings;
		info.page = ("page" in req.query) ? to!int(req.query["page"])-1 : 0;
		m_ctrl.enumerateUsers(info.page*info.itemsPerPage, info.itemsPerPage, (ref user){
			info.users ~= getUserInfo(m_ctrl, user);
		});
		info.itemCount = cast(int)m_ctrl.getUserCount();
		info.pageCount = (info.itemCount-1)/info.itemsPerPage + 1;

		res.render!("vibenews.admin.listusers.dt", req, info);
	}

	void showUser(HTTPServerRequest req, HTTPServerResponse res)
	{
		struct Info {
			VibeNewsSettings settings;
			UserInfo user;
		}
		auto uid = User.ID.fromString(req.params["user"]);
		User usr = m_ctrl.getUser(uid);
		Info info;
		info.settings = m_ctrl.settings;
		info.user = getUserInfo(m_ctrl, usr);
		res.render!("vibenews.admin.edituser.dt", req, info);
	}

	void updateUser(HTTPServerRequest req, HTTPServerResponse res)
	{
		import std.algorithm.iteration : splitter;

		auto uid = User.ID.fromString(req.params["user"]);
		auto user = m_ctrl.getUser(uid);
		if (auto pv = "email" in req.form) {
			validateEmail(*pv);
			user.email = user.name = *pv;
		}
		if (auto pv = "fullName" in req.form) user.fullName = *pv;
		if (auto pv = "groups" in req.form) {
			user.groups.length = 0;
			foreach (grp; (*pv).splitter(",").map!(g => authGroupPrefix ~ g.strip())) {
				try user.groups ~= m_ctrl.getAuthGroupByName(grp).id;
				catch (Exception) {
					m_ctrl.userManController.addGroup(grp, "VibeNews authentication group");
					user.groups ~= m_ctrl.getAuthGroupByName(grp).id;
				}
			}
		}
		user.active = ("active" in req.form) !is null;
		user.banned = ("banned" in req.form) !is null;
		m_ctrl.updateUser(user);

		res.redirect("/users/");
	}

	void deleteUser(HTTPServerRequest req, HTTPServerResponse res)
	{
		m_ctrl.deleteUser(User.ID.fromString(req.params["user"]));
		res.redirect("/users/");
	}

	void postDeleteOrphanedUsers(HTTPServerRequest req, HTTPServerResponse res)
	{
		m_ctrl.deleteOrphanedUsers();
		res.redirect("/users/");
	}

}

struct UserInfo {
	User user;
	alias user this;
	ulong messageCount;
	ulong deletedMessageCount;
	string[] groupStrings;
}

private UserInfo getUserInfo(Controller ctrl, User user)
{
	UserInfo nfo;
	nfo.user = user;
	ctrl.getUserMessageCount(user.email, nfo.messageCount, nfo.deletedMessageCount);
	foreach (grpname; user.groups) {
		if (!grpname.startsWith(authGroupPrefix)) continue;
		grpname = grpname[authGroupPrefix.length .. $];
		nfo.groupStrings ~= grpname;
	}
	return nfo;
}
