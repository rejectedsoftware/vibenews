/**
	(module summary)

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.nntp.status;

enum NntpStatus {
	HelpText = 100,
	TimeFollows = 111,
	DebugOutput = 199,
	ServerReady = 200,
	ServerReadyNoPosting = 201,
	SlaveStatusNoted = 202,
	ClosingConnection = 205,
	GroupSelected = 211,
	Groups = 215,
	Article = 220,
	Head = 221,
	Body = 222,
	OverviewFollows = 224,
	NewArticles = 230,
	NewGroups = 231,
	ArticleTransferredOK = 235,
	ArticlePostedOK = 240,
	AuthAccepted = 281,
	TransferArticle = 340,
	PostArticle = 340,
	MoreAuthInfoRequired = 381,
	ContinueWithTLS = 382,
	ServiceDiscontinued = 400,
	NoSuchGruop = 411,
	NoGroupSelected = 412,
	NoArticleSelected = 420,
	BadArticleNumber = 423,
	BadArticleId = 430,
	DontSendArticle = 435,
	TransferFailed = 436,
	ArticleRejected = 437,
	PostingNotAllowed = 440,
	PostingFailed = 441,
	AuthRequired = 480,
	AuthRejected = 482,
	BadCommand = 500,
	CommandSyntaxError = 501,
	AccessFailure = 502,
	InternalError = 503,
}