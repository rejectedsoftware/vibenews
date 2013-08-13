/**
	Word based bayes spam filter.

	Copyright: © 2013 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibenews.spamfilters.bayes;

import vibenews.message;
import vibenews.vibenews;

import std.datetime;
import std.range;
import std.uni;
import vibe.core.core;
import vibe.core.file;
import vibe.data.json;
import vibe.inet.message;
import vibe.stream.operations;


class BayesSpamFilter : SpamFilter {
	struct Word {
		long spamCount;
		long hamCount;
	}
	private {
		Word[string] m_words;
		long m_spamCount, m_hamCount;
		Timer m_updateTimer;
		bool m_writingWords = false;
	}

	this()
	{
		try {
			auto f = openFile("bayes-words.json");
			scope(exit) f.close();
			auto j = f.readAllUTF8().parseJsonString();
			m_spamCount = j.spamCount.get!long;
			m_hamCount = j.hamCount.get!long;
			foreach (string w, cnt; j.words)
				m_words[w] = Word(cnt.spamCount.get!long, cnt.hamCount.get!long);
		} catch (Exception e) {

		}

		m_updateTimer = createTimer(&writeWordFile);
	}

	@property string id() { return "bayes"; }

	void setSettings(Json settings)
	{
	}

	bool checkForBlock(ref const Article)
	{
		return false;
	}

	bool checkForRevoke(ref const Article art)
	{
		import vibe.core.log;
		double pspam = 1.0;
		double pham = 1.0;

		long count = 0;
		logDebugV("Determining spam status");
		iterateWords(art, (w) {
			if (auto pc = w in m_words) {
				if (pc.spamCount) {
					auto p_w_s = pc.spamCount/cast(double)m_spamCount;
					auto p_w_h = pc.hamCount/cast(double)m_hamCount;
					auto prob = p_w_s / (p_w_s + p_w_h);
					pspam *= prob;
					pham *= 1 - prob;
					logDebugV("%s: %s", w, prob);
				} else logDebugV("%s: no spam word", w);
				count++;
			} else logDebugV("%s: unknown word", w);
		});
		auto prob = pspam / (pspam + pham);
		logDebugV("---- final probability %s", prob);
		return prob > 0.7;
	}

	void resetClassification()
	{
		m_words = null;
		updateDB();
	}

	void classify(in ref Article art, bool spam, bool unclassify = false)
	{
		iterateWords(art, (w) {
			auto cnt = m_words.get(w, Word(0, 0));
			if (unclassify) {
				if (spam) {
					assert(cnt.spamCount > 0, "Unclassifying unknown spam word: "~w);
					cnt.spamCount--;
				} else {
					assert(cnt.hamCount > 0, "Unclassifying unknown ham word: "~w);
					cnt.hamCount--;
				}
			} else {
				if (spam) cnt.spamCount++;
				else cnt.hamCount++;
			}
			m_words[w] = cnt;
		});
		if (unclassify) {
			if (spam) m_spamCount--;
			else m_hamCount--;
		} else {
			if (spam) m_spamCount++;
			else m_hamCount++;
		}
		updateDB();
	}

	private static void iterateWords(in ref Article art, scope void delegate(string) del)
	{
		bool[string] seen;
		iterateWords(decodeMessage(art), del, seen);
		iterateWords(art.getHeader("Subject").decodeEncodedWords(), del, seen);
	}

	private static void iterateWords(string str, scope void delegate(string) del, ref bool[string] seen)
	{
		void handleWord(string word)
		{
			if (word !in seen) {
				seen[word] = true;
				del(word);
			}
		}

		bool inword = false;
		string wordstart;
		while (!str.empty) {
			auto ch = str.front;
			auto isword = ch.isAlpha() || ch.isNumber();
			if (inword && !isword) {
				handleWord(wordstart[0 .. wordstart.length - str.length]);
				inword = false;
			} else if (!inword && isword) {
				wordstart = str;
				inword = true;
			}
			str.popFront();
		}
		if (inword && wordstart.length) handleWord(wordstart);
	}

	private void updateDB()
	{
		m_updateTimer.rearm(1.seconds);
	}

	private void writeWordFile()
	{
		if (m_writingWords) {
			updateDB();
			return;
		}
		m_writingWords = true;
		scope(exit) m_writingWords = false;

		auto words = Json.emptyObject;
		foreach (w, c; m_words) {
			auto jc = Json.emptyObject;
			jc.spamCount = c.spamCount;
			jc.hamCount = c.hamCount;
			words[w] = jc;
		}

		auto j = Json.emptyObject;
		j.spamCount = m_spamCount;
		j.hamCount = m_hamCount;
		j.words = words;

		auto f = openFile("bayes-words.json", FileMode.createTrunc);
		writePrettyJsonString(f, j);
	}
}
