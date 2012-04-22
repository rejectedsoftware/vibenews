module app;

import vibe.d;
import vibe.crypto.passwordhash;

import admin;
import db;
import nntp.server;
import nntp.status;

string g_hostname = "localhost";

// TODO: capabilities, auth, better POST validation, message codes when exceptions happen

void article(NntpServerRequest req, NntpServerResponse res)
{
	req.enforceNParams(1);
	auto anum = to!long(req.parameters[0]);

	if( !isTaskLocalSet("group") ){
		res.status = NntpStatus.NoGroupSelected;
		res.statusText = "Not in a newsgroup";
		res.writeVoidBody();
		return;
	}

	auto groupname = getTaskLocal!string("group");

	if( !testAuth(groupname, res) )
		return;

	Article art;
	try art = getArticle(groupname, anum);
	catch( Exception e ){
		res.status = NntpStatus.BadArticleNumber;
		res.statusText = "Bad article number";
		res.writeVoidBody();
		return;
	}

	res.statusText = to!string(art.number[escapeGroup(groupname)])~" "~art.id~" ";
	switch(req.command){
		default: assert(false);
		case "article":
			res.status = NntpStatus.Article;
			res.statusText ~= "article";
			break;
		case "body":
			res.status = NntpStatus.Body;
			res.statusText ~= "body";
			break;
		case "head":
			res.status = NntpStatus.Head;
			res.statusText ~= "head";
			break;
	}

	if( req.command == "head" || req.command == "article" ){
		bool first = true;
		//res.bodyWriter.write("Message-ID: ", false);
		//res.bodyWriter.write(art.id, false);
		//res.bodyWriter.write("\r\n");
		foreach( hdr; art.headers ){
			if( !first ) res.bodyWriter.write("\r\n");
			else first = false;
			res.bodyWriter.write(hdr.key, false);
			res.bodyWriter.write(": ", false);
			res.bodyWriter.write(hdr.value, false);
		}
		if( req.command == "article" )
			res.bodyWriter.write("\r\n\r\n");
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
			setTaskLocal("authPassword", req.parameters[1]);
			res.status = NntpStatus.AuthAccepted;
			res.statusText = "authentication stored";
			res.writeVoidBody();
			break;
	}
}

void group(NntpServerRequest req, NntpServerResponse res)
{
	req.enforceNParams(1, "<groupname>");
	auto groupname = req.parameters[0];
	Group grp;
	try {
		grp = getGroupByName(groupname);
		enforce(grp.active);
	} catch( Exception e ){
		res.status = NntpStatus.NoSuchGruop;
		res.statusText = "No such group "~groupname;
		res.writeVoidBody();
		return;
	}

	if( !testAuth(groupname, res) )
		return;

	setTaskLocal("group", groupname);

	res.status = NntpStatus.GroupSelected;
	res.statusText = to!string(grp.articleCount)~" "~to!string(grp.minArticleNumber)~" "~to!string(grp.maxArticleNumber)~" "~groupname;

	if( req.command == "group" ){
		res.writeVoidBody();
	} else {
		res.statusText = "Article list follows";
		res.bodyWriter();
		enumerateArticles(groupname, (i, id, msgid, msgnum){
				if( i > 0 ) res.bodyWriter.write("\r\n");
				res.bodyWriter.write(to!string(msgnum), false);
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
		default: enforce(false, "Invalid list kind."); assert(false);
		case "newsgroups":
			res.statusText = "Descriptions in form \"group description\".";
			res.bodyWriter();
			size_t cnt = 0;
			enumerateGroups((i, grp){
					if( !grp.active ) return;
					logInfo("Got group %s", grp.name);
					if( cnt++ > 0 ) res.bodyWriter.write("\r\n");
					res.bodyWriter.write(grp.name ~ " " ~ grp.description, false);
				});
			break;
		case "active":
			res.statusText = "Newsgroups in form \"group high low flags\".";
			size_t cnt = 0;
			enumerateGroups((i, grp){
					if( !grp.active ) return;
					if( cnt++ > 0 ) res.bodyWriter.write("\r\n");
					auto high = to!string(grp.maxArticleNumber);
					auto low = to!string(grp.minArticleNumber);
					auto flags = "y";
					res.bodyWriter.write(grp.name~" "~high~" "~low~" "~flags, false);
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

	auto grp = getGroupByName(grpname);
	
	if( !testAuth(grp, res) )
		return;

	long fromnum = to!long(fromstr);
	long tonum = tostr.length ? to!long(tostr) : grp.maxArticleNumber;
	
	res.status = NntpStatus.OverviewFollows;
	res.statusText = "Overview information follows (multi-line)";
	auto dst = res.bodyWriter;
	enumerateArticles(grpname, fromnum, tonum, (idx, art){
		if( idx > 0 ) dst.write("\r\n");
		void writeField(string str){
			dst.write("\t", false);
			dst.write(str, false);
		}
		dst.write(to!string(art.number[escapeGroup(grpname)]));
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
	art.id = "<"~art._id.toString()~"@"~g_hostname~">";

	res.status = NntpStatus.PostArticle;
	res.statusText = "Ok, recommended ID "~art.id;
	res.writeVoidBody();

	while(!req.bodyReader.empty){
		string ln = cast(string)req.bodyReader.readLine();
		if( ln.length == 0 ) break;
		auto idx = ln.countUntil(':');
		enforce(idx > 0);
		art.addHeader(ln[0 .. idx], strip(ln[idx+1 .. $]));
	}

	art.message = cast(string)req.bodyReader.readAll();

	postArticle(art);

	res.restart();
	res.status = NntpStatus.ArticlePostedOK;
	res.statusText = "Article posted";
	res.writeVoidBody();
}

void newnews(NntpServerRequest req, NntpServerResponse res)
{
	req.enforceNParams(3);
	auto grp = req.parameters[0];
	auto dstr = req.parameters[1];
	auto tstr = req.parameters[2];
	int year = to!int(dstr[0 .. 2]);
	year += 2000;
	auto date = DateTime(year, to!int(dstr[2 .. 4]), to!int(dstr[4 .. 6]),
		to!int(tstr[0 .. 2]), to!int(tstr[2 .. 4]), to!int(tstr[4 .. 6]));

	if( !testAuth(grp, res) )
		return;

	res.status = NntpStatus.NewArticles;
	res.statusText = "New news follows";

	enumerateNewArticles(grp, SysTime(date, UTC()), (i, id, msgid, msgnum){
			if( i > 0 ) res.bodyWriter.write("\r\n");
			res.bodyWriter.write(msgid, false);
		});

}

void newgroups(NntpServerRequest req, NntpServerResponse res)
{
	req.enforceNParams(2);
	auto dstr = req.parameters[0];
	auto tstr = req.parameters[1];
	int year = to!int(dstr[0 .. 2]);
	year += 2000;
	auto date = DateTime(year, to!int(dstr[2 .. 4]), to!int(dstr[4 .. 6]),
		to!int(tstr[0 .. 2]), to!int(tstr[2 .. 4]), to!int(tstr[4 .. 6]));

	res.status = NntpStatus.NewGroups;
	res.statusText = "New groups follow";

	size_t cnt = 0;
	enumerateNewGroups(SysTime(date, UTC()), (i, grp){
			if( !grp.active ) return;
			if( cnt++ > 0 ) res.bodyWriter.write("\r\n");
			auto high = to!string(grp.maxArticleNumber);
			auto low = to!string(grp.minArticleNumber);
			auto flags = "y";
			res.bodyWriter.write(grp.name~" "~high~" "~low~" "~flags, false);
		});

}

void starttls(NntpServerRequest req, NntpServerResponse res)
{
	res.status = NntpStatus.ContinueWithTLS;
	res.statusText = "Continue with TLS negotiation";
	res.writeVoidBody();
	res.acceptTLS();
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
		case "starttls": starttls(req, res); break;
		case "xover": over(req, res); break;
	}
}

bool testAuth(string grpname, NntpServerResponse res = null)
{
	auto grp = getGroupByName(grpname);
	return testAuth(grp, res);
}

bool testAuth(Group grp, NntpServerResponse res = null)
{
	if( grp.username.length == 0 ) return true;
	if( !isTaskLocalSet("authUser") || !isTaskLocalSet("authPassword") ){
		if( res ){
			res.status = NntpStatus.AuthRequired;
			res.statusText = "auth info required";
			res.writeVoidBody();
		}
		return false;
	}
	auto user = getTaskLocal!string("authUser");
	auto pass = getTaskLocal!string("authPassword");
	if( user != grp.username || !testSimplePasswordHash(grp.passwordHash, pass) ){
		if( res ){
			res.status = NntpStatus.AccessFailure;
			res.statusText = "auth info not valid for group";
			res.writeVoidBody();
		}
		return false;
	}
	return true;
}

static this()
{
	auto settings = new NntpServerSettings;
	//settings.port = 563;
	//settings.sslCert = "server.crt";
	//settings.sslKey = "server.key";
	listenNntp(settings, toDelegate(&handleCommand));

	startAdminInterface();
}