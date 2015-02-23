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

The following ports are now available, per the default `settings.json` file:

 - :119 provides the NNTP interface
 - 127.0.0.1:8009 provides the HTTP web interface
 - 127.0.0.1:9009 provides the admin interface

You can leave these settings unchanged if you use a reverse proxy to make the web forum available to the public. Alternatively, you change the settings file to make the web forum directly reachable from the Internet. You can delete the key `webBindAddresses` to listen on the default network interfaces or you can provide your own list of bind addresses.

Example `settings.json`:

```
{
	"title": "Example Forum",
	"host": "forum.example.org",
	"nntpPort": 119,
	"webPort": 80,
	"adminPort": 9009,
	"adminBindAddresses": ["127.0.0.1"],
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
