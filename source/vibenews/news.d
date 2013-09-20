/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.news;

import vibenews.nntp.server;
import vibenews.nntp.status;
import vibenews.controller;
import vibenews.vibenews;

import antispam.antispam;
import vibe.core.core;
import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.data.bson;
import vibe.inet.message;
import vibe.stream.counting;
import vibe.stream.operations;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.format;
import std.string;


// TODO: capabilities, auth, better POST validation, message codes when exceptions happen

class NewsInterface {
	private {
		Controller m_ctrl;
		VibeNewsSettings m_settings;
	}

	this(Controller controller)
	{
		m_ctrl = controller;
		m_settings = controller.settings;

		auto nntpsettings = new NntpServerSettings;
		nntpsettings.requireSsl = m_settings.requireSsl;
		nntpsettings.host = m_settings.hostName;
		nntpsettings.port = m_settings.nntpPort;
		listenNntp(nntpsettings, &handleCommand);

		if( m_settings.sslCertFile.length || m_settings.sslKeyFile.length ){
			auto nntpsettingsssl = new NntpServerSettings;
			nntpsettingsssl.host = m_settings.hostName;
			nntpsettingsssl.port = m_settings.nntpSslPort;
			nntpsettingsssl.enableSsl = true;
			nntpsettingsssl.sslCertFile = m_settings.sslCertFile;
			nntpsettingsssl.sslKeyFile = m_settings.sslKeyFile;
			listenNntp(nntpsettingsssl, &handleCommand);
		}
	}

	void handleCommand(NntpServerRequest req, NntpServerResponse res)
	{
		switch( req.command ){
			default:
				res.status = NntpStatus.BadCommand;
				res.statusText = "Unsupported command: "~req.command;
				res.writeVoidBody();
				break;
			case "article": article(req, res); break;
			case "authinfo": authinfo(req, res); break;
			case "body": article(req, res); break;
			// capabilities
			case "date": date(req, res); break;
			case "group": group(req, res); break;
			case "head": article(req, res); break;
			case "help": help(req, res); break;
			// ihave
			// last
			case "list": list(req, res); break;
			case "listgroup": group(req, res); break;
			case "mode": mode(req, res); break;
			case "newgroups": newgroups(req, res); break;
			case "newnews": newnews(req, res); break;
			// next
			case "over": over(req, res); break;
			case "post": post(req, res); break;
			case "xover": over(req, res); break;
		}
	}

	DateTime parseDateParams(string[] params, NntpServerRequest req)
	{
		int extendYear(int two_digit_year)
		{
			if( two_digit_year >= 70 ) return 1900+two_digit_year;
			else return 2000 + two_digit_year;
		}

		req.enforce(params.length == 2 || params[2] == "GMT",
			NntpStatus.CommandSyntaxError, "Time zone must be GMT");

		auto dstr = params[0];
		auto tstr = params[1];

		req.enforce(dstr.length == 6 || dstr.length == 8,
			NntpStatus.CommandSyntaxError, "YYMMDD or YYYYMMDD");

		bool fullyear = dstr.length == 8;
		dstr ~= "11"; // just to avoid array out-of-bounds
		int year = fullyear ? to!int(dstr[0 .. 4]) : extendYear(to!int(dstr[0 .. 2]));
		int month = fullyear ? to!int(dstr[4 .. 6]) : to!int(dstr[2 .. 4]);
		int day = fullyear ? to!int(dstr[6 .. 8]) : to!int(dstr[4 .. 6]);
		int hour = to!int(tstr[0 .. 2]);
		int minute = to!int(tstr[2 .. 4]);
		int second = to!int(tstr[4 .. 6]);
		return DateTime(year, month, day, hour, minute, second);
	}

	void article(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(1);

		Article art;
		if( req.parameters[0].startsWith("<") ){
			try art = m_ctrl.getArticle(req.parameters[0]);
			catch( Exception e ){
				res.status = NntpStatus.BadArticleId;
				res.statusText = "Bad article id";
				res.writeVoidBody();
				return;
			}

			bool auth = false;
			foreach( g; art.groups.byKey() ){
				if( testAuth(unescapeGroup(g), false) ){
					auth = true;
					break;
				}
			}
			if( !auth ){
				res.status = NntpStatus.AccessFailure;
				res.statusText = "Not authorized to access this article";
				res.writeVoidBody();
				return;
			}

			res.statusText = "0 "~art.id~" ";
		} else {
			auto anum = to!long(req.parameters[0]);

			if( !isTaskLocalSet("group") ){
				res.status = NntpStatus.NoGroupSelected;
				res.statusText = "Not in a newsgroup";
				res.writeVoidBody();
				return;
			}

			auto groupname = getTaskLocal!string("group");

			if( !testAuth(groupname, false, res) )
				return;

			try art = m_ctrl.getArticle(groupname, anum);
			catch( Exception e ){
				res.status = NntpStatus.BadArticleNumber;
				res.statusText = "Bad article number";
				res.writeVoidBody();
				return;
			}

			res.statusText = to!string(art.groups[escapeGroup(groupname)].articleNumber)~" "~art.id~" ";
		}

		switch(req.command){
			default: assert(false);
			case "article":
				res.status = NntpStatus.Article;
				res.statusText ~= "head and body follow";
				break;
			case "body":
				res.status = NntpStatus.Body;
				res.statusText ~= "body follows";
				break;
			case "head":
				res.status = NntpStatus.Head;
				res.statusText ~= "head follows";
				break;
		}

		if( req.command == "head" || req.command == "article" ){
			bool first = true;
			//res.bodyWriter.write("Message-ID: ", false);
			//res.bodyWriter.write(art.id, false);
			//res.bodyWriter.write("\r\n");
			auto dst = res.bodyWriter;
			foreach( hdr; art.headers ){
				if( !first ) dst.write("\r\n");
				else first = false;
				dst.write(hdr.key);
				dst.write(": ");
				dst.write(hdr.value);
			}
			
			// write Xref header
			dst.write("\r\n");
			dst.write("Xref: ");
			dst.write(m_settings.hostName);
			foreach( grpname, grpref; art.groups ){
				dst.write(" ");
				dst.write(unescapeGroup(grpname));
				dst.write(":");
				dst.write(to!string(grpref.articleNumber));
			}
			
			if( req.command == "article" )
				dst.write("\r\n\r\n");
		}

		if( req.command == "body" || req.command == "article" ){
			res.bodyWriter.write(art.message);
		}
	}

	void authinfo(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(2, "USER/PASS <value>");
		
		switch(req.parameters[0].toLower()){
			default:
				res.status = NntpStatus.CommandSyntaxError;
				res.statusText = "USER/PASS <value>";
				res.writeVoidBody();
				break;
			case "user":
				setTaskLocal("authUser", req.parameters[1]);
				res.status = NntpStatus.MoreAuthInfoRequired;
				res.statusText = "specify password";
				res.writeVoidBody();
				break;
			case "pass":
				req.enforce(isTaskLocalSet("authUser"), NntpStatus.AuthRejected, "specify user first");
				auto password = req.parameters[1];
				try {
					auto usr = m_ctrl.getUserByEmail(getTaskLocal!string("authUser"));
					enforce(testSimplePasswordHash(usr.auth.passwordHash, password));
					setTaskLocal("authUserId", usr._id.toString());
					res.status = NntpStatus.AuthAccepted;
					res.statusText = "authentication successful";
					res.writeVoidBody();
				} catch( Exception e ){
					res.status = NntpStatus.AuthRejected;
					res.statusText = "authentication failed";
					res.writeVoidBody();
				}
				break;
		}
	}

	void date(NntpServerRequest req, NntpServerResponse res)
	{
		res.status = NntpStatus.TimeFollows;
		auto tm = Clock.currTime(UTC());
		auto tmstr = appender!string();
		formattedWrite(tmstr, "%04d%02d%02d%02d%02d%02d", tm.year, tm.month, tm.day,
				tm.hour, tm.minute, tm.second);
		res.statusText = tmstr.data;
		res.writeVoidBody();
	}

	void group(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(1, "<groupname>");
		auto groupname = req.parameters[0];
		vibenews.controller.Group grp;
		try {
			grp = m_ctrl.getGroupByName(groupname);
			enforce(grp.active);
		} catch( Exception e ){
			res.status = NntpStatus.NoSuchGruop;
			res.statusText = "No such group "~groupname;
			res.writeVoidBody();
			return;
		}

		if( !testAuth(groupname, false, res) )
			return;

		setTaskLocal("group", groupname);

		res.status = NntpStatus.GroupSelected;
		res.statusText = to!string(grp.articleCount)~" "~to!string(grp.minArticleNumber)~" "~to!string(grp.maxArticleNumber)~" "~groupname;

		if( req.command == "group" ){
			res.writeVoidBody();
		} else {
			res.statusText = "Article list follows";
			res.bodyWriter();
			m_ctrl.enumerateArticles(groupname, (i, id, msgid, msgnum){
					if( i > 0 ) res.bodyWriter.write("\r\n");
					res.bodyWriter.write(to!string(msgnum));
				});
		}
	}

	void help(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(0);
		res.status = NntpStatus.HelpText;
		res.statusText = "Legal commands";
		res.bodyWriter.write("  help\r\n");
		res.bodyWriter.write("  list Kind\r\n");
	}

	void list(NntpServerRequest req, NntpServerResponse res)
	{
		if( req.parameters.length == 0 )
			req.parameters ~= "active";

		res.status = NntpStatus.Groups;
		switch( toLower(req.parameters[0]) ){
			default: enforce(false, "Invalid list kind: "~req.parameters[0]); assert(false);
			case "newsgroups":
				res.statusText = "Descriptions in form \"group description\".";
				res.bodyWriter();
				size_t cnt = 0;
				m_ctrl.enumerateGroups((i, grp){
						if( !grp.active ) return;
						logDebug("Got group %s", grp.name);
						if( cnt++ > 0 ) res.bodyWriter.write("\r\n");
						res.bodyWriter.write(grp.name ~ " " ~ grp.description);
					});
				break;
			case "active":
				res.statusText = "Newsgroups in form \"group high low flags\".";
				size_t cnt = 0;
				m_ctrl.enumerateGroups((i, grp){
						if( !grp.active ) return;
						if( cnt++ > 0 ) res.bodyWriter.write("\r\n");
						auto high = to!string(grp.maxArticleNumber);
						auto low = to!string(grp.minArticleNumber);
						auto flags = "y";
						res.bodyWriter.write(grp.name~" "~high~" "~low~" "~flags);
					});
				break;
		}
	}

	void mode(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(1, "READER");
		if( toLower(req.parameters[0]) != "reader" ){
			res.status = NntpStatus.CommandSyntaxError;
			res.statusText = "Expected MODE READER";
		} else {
			res.status = NntpStatus.ServerReady;
			res.statusText = "Posting allowed";
		}
		res.writeVoidBody();
	}

	void over(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(1, "(X)OVER [range]");
		req.enforce(isTaskLocalSet("group"), NntpStatus.NoGroupSelected, "No newsgroup selected");
		auto grpname = getTaskLocal!string("group");
		auto idx = req.parameters[0].countUntil('-');
		string fromstr, tostr;
		if( idx > 0 ){
			fromstr = req.parameters[0][0 .. idx];
			tostr = req.parameters[0][idx+1 .. $];
		} else fromstr = tostr = req.parameters[0];

		auto grp = m_ctrl.getGroupByName(grpname);
		
		if( !testAuth(grp, false, res) )
			return;

		long fromnum = to!long(fromstr);
		long tonum = tostr.length ? to!long(tostr) : grp.maxArticleNumber;
		
		res.status = NntpStatus.OverviewFollows;
		res.statusText = "Overview information follows (multi-line)";
		auto dst = res.bodyWriter;
		m_ctrl.enumerateArticles(grpname, fromnum, tonum, (idx, art){
			if( idx > 0 ) dst.write("\r\n");
			void writeField(string str){
				dst.write("\t");
				dst.write(str);
			}
			dst.write(to!string(art.groups[escapeGroup(grpname)].articleNumber));
			writeField(art.getHeader("Subject"));
			writeField(art.getHeader("From"));
			writeField(art.getHeader("Date"));
			writeField(art.getHeader("Message-ID"));
			writeField(art.getHeader("References"));
			writeField(to!string(art.messageLength));
			writeField(to!string(art.messageLines));
			foreach( h; art.headers ){
				if( icmp(h.key, "Subject") == 0 ) continue;
				if( icmp(h.key, "From") == 0 ) continue;
				if( icmp(h.key, "Date") == 0 ) continue;
				if( icmp(h.key, "Message-ID") == 0 ) continue;
				if( icmp(h.key, "References") == 0 ) continue;
				writeField(h.key ~ ": " ~ h.value);
			}
		});
	}

	void post(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(0);
		Article art;
		art._id = BsonObjectID.generate();
		art.id = "<"~art._id.toString()~"@"~m_settings.hostName~">";

		res.status = NntpStatus.PostArticle;
		res.statusText = "Ok, recommended ID "~art.id;
		res.writeVoidBody();

		InetHeaderMap headers;
		parseRFC5322Header(req.bodyReader, headers);
		foreach( k, v; headers ) art.addHeader(k, v);

		auto limitedReader = new LimitedInputStream(req.bodyReader, 2048*1024, true);

		try {
			art.message = limitedReader.readAll();
		} catch( LimitException e ){
			auto sink = new NullOutputStream;
			sink.write(req.bodyReader);
			res.restart();
			res.status = NntpStatus.ArticleRejected;
			res.statusText = "Message too big, please keep below 2.0 MiB";
			res.writeVoidBody();
			return;
		}
		res.restart();
		art.peerAddress = [req.peerAddress];

		// check for spam
		auto msg = toAntispamMessage(art);
		bool reject = false;
		foreach( flt; m_settings.spamFilters ) {
			auto status = flt.determineImmediateSpamStatus(msg);
			if (status == SpamAction.block) {
				res.status = NntpStatus.ArticleRejected;
				res.statusText = "Message deemed abusive.";
				res.writeVoidBody();
				return;
			} else if (status == SpamAction.revoke) reject = true;
		}

		BsonObjectID uid;
		if( isTaskLocalSet("authUserId") ) uid = BsonObjectID.fromString(getTaskLocal!string("authUserId"));
		m_ctrl.postArticle(art, uid);

		if (reject) {
			m_ctrl.markAsSpam(art._id, true);
			res.status = NntpStatus.ArticleRejected;
			res.statusText = "Message deemed abusive.";
			res.writeVoidBody();
			return;
		}

		res.status = NntpStatus.ArticlePostedOK;
		res.statusText = "Article posted";
		res.writeVoidBody();

		runTask({
			foreach (flt; m_settings.spamFilters)
				if (flt.determineAsyncSpamStatus(msg) != SpamAction.pass) {
					m_ctrl.markAsSpam(art._id, true);
					return;
				}
			m_ctrl.markAsSpam(art._id, false);
		});
	}

	void newnews(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(3, 4);
		auto grp = req.parameters[0];
		auto date = parseDateParams(req.parameters[1 .. $], req);

		if( grp == "*" ){
			res.status = NntpStatus.NewArticles;
			res.statusText = "New news follows";

			auto writer = res.bodyWriter();

			bool first = true;
			m_ctrl.enumerateGroups((gi, group){
				if( !testAuth(group.name, false, res) )
					return;
					
				m_ctrl.enumerateNewArticles(group.name, SysTime(date, UTC()), (i, id, msgid, msgnum){
						if( !first ) writer.write("\r\n");
						first = false;
						writer.write(msgid);
					});
			});
		} else {
			if( !testAuth(grp, false, res) )
				return;

			res.status = NntpStatus.NewArticles;
			res.statusText = "New news follows";

			auto writer = res.bodyWriter();

			m_ctrl.enumerateNewArticles(grp, SysTime(date, UTC()), (i, id, msgid, msgnum){
					if( i > 0 ) writer.write("\r\n");
					writer.write(msgid);
				});
		}
	}

	void newgroups(NntpServerRequest req, NntpServerResponse res)
	{
		req.enforceNParams(2, 3);
		auto date = parseDateParams(req.parameters[0 .. $], req);

		res.status = NntpStatus.NewGroups;
		res.statusText = "New groups follow";

		auto writer = res.bodyWriter();

		size_t cnt = 0;
		m_ctrl.enumerateNewGroups(SysTime(date, UTC()), (i, grp){
				if( !grp.active ) return;
				if( cnt++ > 0 ) writer.write("\r\n");
				auto high = to!string(grp.maxArticleNumber);
				auto low = to!string(grp.minArticleNumber);
				auto flags = "y";
				writer.write(grp.name~" "~high~" "~low~" "~flags);
			});

	}

	bool testAuth(string grpname, bool require_write, NntpServerResponse res = null)
	{
		try {
			auto grp = m_ctrl.getGroupByName(grpname);
			return testAuth(grp,require_write, res);
		} catch( Exception e ){
			return false;
		}
	}

	bool testAuth(vibenews.controller.Group grp, bool require_write, NntpServerResponse res)
	{
		if( grp.readOnlyAuthTags.empty && grp.readWriteAuthTags.empty )
			return true;

		BsonObjectID uid;
		try uid = BsonObjectID.fromString(getTaskLocal!string("authUserId"));
		catch(Exception){
			if( res ){
				res.status = NntpStatus.AuthRequired;
				res.statusText = "auth info required";
				res.writeVoidBody();
			}
			return false;
		}

		try {
			if( require_write )
				enforce(m_ctrl.isAuthorizedForWritingGroup(uid, grp.name));
			else enforce(m_ctrl.isAuthorizedForReadingGroup(uid, grp.name));
			return true;
		} catch(Exception){
			if( res ){
				res.status = NntpStatus.AccessFailure;
				res.statusText = "auth info not valid for group";
				res.writeVoidBody();
			}
			return false;
		}
	}
}
