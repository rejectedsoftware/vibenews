module vibenews.message;

import vibenews.controller;

import std.algorithm;
import std.array;
import std.base64;
import std.string;
import std.uni;
import vibe.inet.message;
import vibe.utils.string;


string decodeMessage(in ref Article art)
{
	const(ubyte)[] msg = art.message;
	switch( art.getHeader("Content-Transfer-Encoding").toLower() ){
		default: break;
		case "quoted-printable": msg = QuotedPrintable.decode(cast(string)msg); break;
		case "base64":
			try msg = Base64.decode(msg);
			catch(Exception e){
				auto dst = appender!(ubyte[])();
				try {
					auto dec = Base64.decoder(msg.filter!(ch => ch != '\r' && ch != '\n')());
					while( !dec.empty ){
						dst.put(dec.front);
						dec.popFront();
					}
				} catch(Exception e){
					dst.put(cast(ubyte[])"\r\n-------\r\nDECODING ERROR: ");
					dst.put(cast(ubyte[])e.toString());
				}
				msg = dst.data();
			}
			break;
	}
	// TODO: do character encoding etc.
	return sanitizeUTF8(msg);
}
