/**
	(module summary)

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.nntp.status;

enum NNTPStatus {
	helpText = 100,
	timeFollows = 111,
	debugOutput = 199,
	serverReady = 200,
	serverReadyNoPosting = 201,
	slaveStatusNoted = 202,
	closingConnection = 205,
	groupSelected = 211,
	groups = 215,
	article = 220,
	head = 221,
	body_ = 222,
	overviewFollows = 224,
	newArticles = 230,
	newGroups = 231,
	articleTransferredOK = 235,
	articlePostedOK = 240,
	authAccepted = 281,
	transferArticle = 340,
	postArticle = 340,
	moreAuthInfoRequired = 381,
	continueWithTLS = 382,
	serviceDiscontinued = 400,
	noSuchGruop = 411,
	noGroupSelected = 412,
	noArticleSelected = 420,
	badArticleNumber = 423,
	badArticleId = 430,
	dontSendArticle = 435,
	transferFailed = 436,
	articleRejected = 437,
	postingNotAllowed = 440,
	postingFailed = 441,
	authRequired = 480,
	authRejected = 482,
	badCommand = 500,
	commandSyntaxError = 501,
	accessFailure = 502,
	commandUnavailable = 502,
	internalError = 503,
	tlsFailed = 580,

	// deprecated
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
	CommandUnavailable = 502,
	InternalError = 503,
	TLSFailed = 580
}

deprecated alias NntpStatus = NNTPStatus;


class NNTPStatusException : Exception {
	private {
		NNTPStatus m_status;
		string m_statusText;
	}

	this(NNTPStatus status, string text, Throwable next = null, string file = __FILE__, int line = __LINE__)
	{
		super(text, file, line, next);
		m_status = status;
		m_statusText = text;
	}

	@property NNTPStatus status() const { return m_status; }
	@property string statusText() const { return m_statusText; }
}

deprecated alias NntpStatusException = NNTPStatusException;
