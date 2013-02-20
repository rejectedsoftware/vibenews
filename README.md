vibenews
========

NNTP server/web forum implementation for stand-alone newsgroups

See <http://news.rejectedsoftware.com/> for a running version.


Features
--------

 - Acts as newsgroup server (NNTP)
 - Acts as a web forum
 - Lightning fast
 - Supports access restriction for individual groups
 - The web forum allows github style markdown formatting
 - Mobile friendly default layout with gravatar integration


Installation
------------

1. Install [dub](https://github.com/rejectedsoftware/dub/) and [MongoDB](http://www.mongodb.org/).

2. Clone the project

        git clone git://github.com/rejectedsoftware/vibenews.git
    
3. Compile and run

        cd vibenews
        dub run

The following ports are now available:

 - :119 provides the NNTP interface
 - 127.0.0.1:8009 provides the HTTP web interface
 - 127.0.0.1:9009 provides the admin interface

You probably want to put the web forum behind a reverse proxy to make it available to the public. Alternatively, you can also create a `settings.json` file and change the web interface port among other things.

Example `settings.json`:

```
{
	"title": "Example Forum",
	"hostName": "forum.example.org",
	"nntpPort": 119,
	"webPort": 8009,
	"adminPort": 9009,
	"googleSearch": true,
	"spamfilters": {
		"blacklist": {
			"ips": ["123.123.123.123"]
		}
	}
}
```


Setup
-----

1. Open the admin interface at <http://127.0.0.1:9009/>

2. Create a new group (use dot.separated.newsgroup.syntax for the name) and make it active

3. Go to <http://127.0.0.1:8009> to view the web forum
