# voice.awk: the voice-contract guard and the reference prompt assembler.
# check.sh runs it with -v mode=check, assemble.sh with -v mode=system.
# POSIX awk. Callers set LC_ALL=C so length() counts UTF-8 bytes.

BEGIN {
	Q = "\047"
	PROFANITY = " shit shits shitty bullshit fuck fucks fucked fucking damn damned goddamn hell crap crappy ass asses piss pissed "
	FWORDS = " fuck fucks fucked fucking "
	# Locked markup: a reply may neither add nor drop these (`$` is locked
	# because dogbed renders `$…$` as math). `*`, `` ` `` and `~` are the
	# insertable set: drops still fail, adds are checked by the pairing
	# rules below and the plain-slot rule.
	LOCKED = "_|#<>[]{}^@\\\"$"
	INSERT = "*`~"
	# Emoji classes as UTF-8 byte patterns (LC_ALL=C: bytes, not chars).
	# Allowed: U+1F300–1F5FF, 1F600–1F64F, 1F680–1F6FF, 1F900–1F9FF,
	# 1FA70–1FAFF plus the dingbats ✨ ⚡ ⚠ ✅ ❌ ☕.
	EMOJI = "\360\237[\214-\227][\200-\277]|\360\237[\230-\231][\200-\277]|\360\237[\232-\233][\200-\277]|\360\237[\244-\247][\200-\277]|\360\237[\251-\253][\200-\277]|\342\230\225|\342\232[\240\241]|\342\234[\205\250]|\342\235\214"
	# Disallowed even inside those blocks, plus skin tones 1F3FB–1F3FF.
	NOEMOJI = "\360\237\226\225|\360\237\215[\206\221]|\360\237\222[\246\243]|\360\237\224[\252\253]|\360\237\227\241|\360\237\252\223|\360\237\251\270|\360\237\217[\273-\277]"
	# ZWJ, SHY, 200B–200F, 202A–202E, 2060–2064, 2066–2069, FEFF.
	INVISIBLE = "\342\200[\213-\217]|\302\255|\342\200[\252-\256]|\342\201[\240-\244]|\342\201[\246-\251]|\357\273\277"
	VS16 = "\357\270\217"
	# ‼ U+203C and ⁉ U+2049 read as !!.
	BANGBYTES = "\342\200\274|\342\201\211"
	for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i
	URLRE = "https?://[^ \t\"'<>)]+"
	NUMRE = "[$#~<>A-Za-z0-9.,%/:_+-]*[0-9][$#~<>A-Za-z0-9.,%/:_+-]*"
	split("mild spicy feral", TONES, " ")
	MAXPROF["mild"] = 0; MAXPROF["spicy"] = 1; MAXPROF["feral"] = 2
	MAXCAPS["mild"] = 0; MAXCAPS["spicy"] = 1; MAXCAPS["feral"] = 3
	MAXBANG["mild"] = 0; MAXBANG["spicy"] = 1; MAXBANG["feral"] = 2
	MAXSPANS["mild"] = 1; MAXSPANS["spicy"] = 2; MAXSPANS["feral"] = 3
	MAXEMOJI["mild"] = 0; MAXEMOJI["spicy"] = 1; MAXEMOJI["feral"] = 2
	MINEX = 6
	split("template field field_role input output", tmp, " ")
	for (i in tmp) REQ[tmp[i]] = 1
	if (mode != "check" && mode != "system") {
		print "voice.awk: set -v mode=check or -v mode=system" > "/dev/stderr"
		ERR = 1
		exit 2
	}
}

# ---- JSONL: one flat object per line, every value a string ----------------

function jstring(s, i,    n, c, out, start) {
	if (substr(s, i, 1) != "\"") return -1
	n = length(s); i++; start = i; out = ""
	while (i <= n) {
		c = substr(s, i, 1)
		if (c == "\"") { JRAW = substr(s, start, i - start); JSTR = out; return i + 1 }
		if (c == "\\") {
			i++; c = substr(s, i, 1)
			if (c == "\"" || c == "\\" || c == "/") out = out c
			else if (c == "n") out = out "\n"
			else if (c == "t") out = out "\t"
			else if (c == "r") out = out "\r"
			else if (c == "u") return -2
			else return -1
		} else out = out c
		i++
	}
	return -1
}

function skipws(s, i) {
	while (i <= length(s) && index(" \t\r", substr(s, i, 1))) i++
	return i
}

function jerr(m) { JERR = m; return -1 }

# Fills J[key] (decoded) and JR[key] (raw, still JSON-escaped).
function jparse(s,    i, n, c, key) {
	split("", J); split("", JR); JERR = ""; n = 0
	i = skipws(s, 1)
	if (substr(s, i, 1) != "{") return jerr("not a JSON object")
	i = skipws(s, i + 1)
	while (1) {
		i = jstring(s, i)
		if (i < 0) return jerr("expected a string key")
		key = JSTR
		i = skipws(s, i)
		if (substr(s, i, 1) != ":") return jerr("expected : after \"" key "\"")
		i = jstring(s, skipws(s, i + 1))
		if (i == -2) return jerr("\\u escape in \"" key "\"; write raw UTF-8 instead")
		if (i < 0) return jerr("value of \"" key "\" must be a string")
		if (key in J) return jerr("duplicate key \"" key "\"")
		J[key] = JSTR; JR[key] = JRAW; n++
		i = skipws(s, i)
		c = substr(s, i, 1)
		if (c == ",") { i = skipws(s, i + 1); continue }
		if (c != "}") return jerr("expected , or }")
		if (skipws(s, i + 1) <= length(s)) return jerr("text after the object")
		return n
	}
}

# ---- protected tokens ------------------------------------------------------

function trimtail(t, chars) {
	while (length(t) > 0 && index(chars, substr(t, length(t), 1))) t = substr(t, 1, length(t) - 1)
	return t
}

# True when w occurs in s with no letter or digit on either side.
function hasword(s, w,    off, p, b, a) {
	off = 0
	while ((p = index(substr(s, off + 1), w)) > 0) {
		p += off
		b = (p == 1) ? "" : substr(s, p - 1, 1)
		a = substr(s, p + length(w), 1)
		if (b !~ /[A-Za-z0-9]/ && a !~ /[A-Za-z0-9]/) return 1
		off = p
	}
	return 0
}

function present(s, t, kind) {
	if (kind == "url" || kind == "wikilink" || kind == "footnote ref" || kind == "quote") return index(s, t) > 0
	return hasword(s, t)
}

function urls(s, T,    rest) {
	rest = s
	while (match(rest, URLRE)) {
		T[trimtail(substr(rest, RSTART, RLENGTH), ".,;:!?")] = "url"
		rest = substr(rest, RSTART + RLENGTH)
	}
}

function spans(s, T, opener, closer, kind,    rest, p, q) {
	rest = s
	while ((p = index(rest, opener)) > 0) {
		rest = substr(rest, p)
		q = index(substr(rest, length(opener) + 1), closer)
		if (q == 0) { T[rest] = kind; return }
		T[substr(rest, 1, length(opener) + q - 1 + length(closer))] = kind
		rest = substr(rest, length(opener) + q + length(closer))
	}
}

# "double" spans, and 'single' spans whose quotes are not apostrophes.
function quotes(s, T,    n, i, j, c) {
	n = length(s); i = 1
	while (i <= n) {
		c = substr(s, i, 1)
		if (c == "\"") {
			j = index(substr(s, i + 1), "\"")
			if (j == 0) return
			T[substr(s, i, j + 1)] = "quote"
			i += j + 1
			continue
		}
		if (c == Q && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9]/)) {
			for (j = i + 1; j <= n; j++)
				if (substr(s, j, 1) == Q && substr(s, j + 1, 1) !~ /[A-Za-z0-9]/) break
			if (j <= n && j > i + 1) { T[substr(s, i, j - i + 1)] = "quote"; i = j + 1; continue }
		}
		i++
	}
}

function numbers(s, T,    rest) {
	rest = s
	while (match(rest, NUMRE)) {
		T[trimtail(substr(rest, RSTART, RLENGTH), ".,:/_+-")] = "number"
		rest = substr(rest, RSTART + RLENGTH)
	}
}

# name: two or more capitals with lowercase (AcmeDB, PhD). acronym: all
# capitals (WAL). proper noun: one leading capital, not at a sentence start.
function names(s, T,    rest, off, p, w, up, lo, nu, nl, pre) {
	rest = s; off = 0
	while (match(rest, /[A-Za-z0-9]+/)) {
		w = substr(rest, RSTART, RLENGTH)
		p = off + RSTART
		off = p + RLENGTH - 1
		rest = substr(rest, RSTART + RLENGTH)
		if (w ~ /[0-9]/) continue
		up = w; lo = w
		nu = gsub(/[A-Z]/, "", up); nl = gsub(/[a-z]/, "", lo)
		if (nu >= 2) { T[w] = (nl > 0) ? "name" : "acronym"; continue }
		if (nu != 1 || length(w) < 2 || substr(w, 1, 1) !~ /[A-Z]/ || (w in T)) continue
		pre = trimtail(substr(s, 1, p - 1), " \t\"([" Q)
		if (pre != "" && !index(".!?", substr(pre, length(pre), 1))) T[w] = "proper noun"
	}
}

function facts(s, T) {
	split("", T)
	urls(s, T)
	spans(s, T, "[[", "]]", "wikilink")
	spans(s, T, "[^", "]", "footnote ref")
	quotes(s, T)
	numbers(s, T)
	names(s, T)
}

# ---- the guard -------------------------------------------------------------

function why(m) { REASONS = REASONS (REASONS == "" ? "" : "; ") m }

# Occurrences of a single literal character (MARKUP chars are regex metas).
function countchar(s, c,    n, p, rest) {
	n = 0; rest = s
	while ((p = index(rest, c)) > 0) { n++; rest = substr(rest, p + 1) }
	return n
}

# The code point of one UTF-8 sequence, for U+XXXX reason strings.
function cpof(seq,    b1, b2, b3, b4) {
	b1 = ORD[substr(seq, 1, 1)]; b2 = ORD[substr(seq, 2, 1)]
	if (length(seq) == 2) return (b1 - 192) * 64 + b2 - 128
	b3 = ORD[substr(seq, 3, 1)]
	if (length(seq) == 3) return (b1 - 224) * 4096 + (b2 - 128) * 64 + b3 - 128
	b4 = ORD[substr(seq, 4, 1)]
	return (b1 - 240) * 262144 + (b2 - 128) * 4096 + (b3 - 128) * 64 + b4 - 128
}

# Pairs `*` runs left to right, `…` spans hidden first. A run can open
# when the next byte isn't space and can close when the previous isn't;
# doing both, it closes iff the stack is non-empty. A closer eats
# min(len) off the top repeatedly (two chars when both sides have them).
# Returns unpaired delimiter chars and fills SPAN["em"], SPAN["strong"].
function starscan(s,    i, n, l, run, prev, nxt, op, cl, sp, use, stack, t, left) {
	gsub(/`[^`]*`/, "x", s)
	n = length(s); i = 1; sp = 0; left = 0
	while (i <= n) {
		if (substr(s, i, 1) != "*") { i++; continue }
		l = 0; while (i + l <= n && substr(s, i + l, 1) == "*") l++
		run = l
		prev = (i == 1) ? " " : substr(s, i - 1, 1)
		nxt = (i + l > n) ? " " : substr(s, i + l, 1)
		op = (nxt !~ /[ \t]/); cl = (prev !~ /[ \t]/)
		if (op && cl) { if (sp > 0) op = 0; else cl = 0 }
		if (cl) {
			while (l > 0 && sp > 0) {
				t = stack[sp]
				use = (t >= 2 && l >= 2) ? 2 : ((t < l) ? t : l)
				stack[sp] -= use; l -= use
				if (use >= 2) SPAN["strong"]++; else SPAN["em"]++
				if (stack[sp] == 0) sp--
			}
			left += l
		} else if (op) {
			stack[++sp] = l
		} else left += l
		i += run
	}
	for (i = 1; i <= sp; i++) left += stack[i]
	return left
}

# Runs of ch in out that the input's multiset can't cover, in AR[len].
function addruns(in_, out, ch,    i, l, rin) {
	split("", rin); split("", AR); i = 1
	while (i <= length(in_)) {
		if (substr(in_, i, 1) != ch) { i++; continue }
		l = 0; while (i + l <= length(in_) && substr(in_, i + l, 1) == ch) l++
		rin[l]++; i += l
	}
	i = 1
	while (i <= length(out)) {
		if (substr(out, i, 1) != ch) { i++; continue }
		l = 0; while (i + l <= length(out) && substr(out, i + l, 1) == ch) l++
		if (rin[l] > 0) rin[l]--; else AR[l]++
		i += l
	}
}

# True when the added runs (AR) are not all `wantlen` or don't pair up.
function added_runs_bad(wantlen,    l, total, bad) {
	total = 0; bad = 0
	for (l in AR) { total += AR[l]; if (l != wantlen) bad = 1 }
	return bad || (total % 2 == 1)
}

# Every non-ASCII sequence in out that the input lacks is classified:
# allowed emoji count toward the tone budget, everything else is hard.
function emojiscan(in_, out,    i, n, b, l, seq, prev, p) {
	EMOJI_COUNT = 0; prev = 0; p = 0
	i = 1; n = length(out)
	while (i <= n) {
		b = substr(out, i, 1)
		if (b !~ /[\200-\377]/) { i++; continue }
		if (b ~ /[\360-\364]/) l = 4
		else if (b ~ /[\340-\357]/) l = 3
		else l = 2
		seq = substr(out, i, l)
		if (seq == VS16) {
			if (index(in_, seq) == 0 && !(prev && p == i)) why("adds invisible character U+FE0F")
			prev = 0
		} else {
			if (index(in_, seq) == 0) {
				if (seq ~ "^(" NOEMOJI ")$") why("adds disallowed emoji U+" sprintf("%X", cpof(seq)))
				else if (seq ~ "^(" INVISIBLE ")$") why("adds invisible character U+" sprintf("%X", cpof(seq)))
				else if (seq ~ "^(" BANGBYTES ")$") why("adds !!")
				else if (seq ~ "^(" EMOJI ")$") EMOJI_COUNT++
				else if (l == 4 || seq ~ /^\342[\230-\236][\200-\277]$/) why("adds symbol U+" sprintf("%X", cpof(seq)))
			}
			prev = (seq ~ "^(" EMOJI ")$"); p = i + l
		}
		i += l
	}
}

# Bytes of s minus `*`, `` ` ``, `~`, allowed emoji and VS16.
function textlen(s,    t, i, n, b, l, seq) {
	t = s; n = length(t); n -= gsub(/[*`~]/, "", t)
	i = 1; n = length(t)
	while (i <= n) {
		b = substr(t, i, 1)
		if (b !~ /[\200-\377]/) { i++; continue }
		l = (b ~ /[\360-\364]/) ? 4 : (b ~ /[\340-\357]/) ? 3 : 2
		seq = substr(t, i, l)
		if (seq == VS16 || seq ~ "^(" EMOJI ")$") t = substr(t, 1, i - 1) substr(t, i + l)
		else i += l
	}
	return length(t)
}

function plainrole(role) {
	return index(role, "rendered bold") || index(role, "rendered italic") || \
		index(role, "alt text") || index(role, "page heading") || index(role, "frontmatter")
}

# Sets REASONS to every way `out` breaks the voice contract for `in_`.
function guard(tone, role, in_, out,    t, i, c, ni, no, L, O, lo, hi, nw, words, tmp, nprof, nf, ncaps, nbang, lin, lou, em_in, em_ou, st_in, st_ou, din, nspans, pj, pk, rest, ent) {
	REASONS = ""
	if (in_ == "") why("empty input")
	if (out == "") { why("empty output"); return }
	if (out == in_) why("output equals input")
	if (in_ ~ /[\001-\037\177]/) why("input has a control character or line break")
	if (out ~ /[\001-\037\177]/) why("control character or line break")

	facts(in_, FI); facts(out, FO)
	for (t in FI) if (!present(out, t, FI[t])) why("drops " FI[t] " " t)
	for (t in FO) if (FO[t] != "acronym" && FO[t] != "proper noun" && !present(in_, t, FO[t])) why("adds " FO[t] " " t)

	for (i = 1; i <= length(LOCKED); i++) {
		c = substr(LOCKED, i, 1)
		ni = countchar(in_, c); no = countchar(out, c)
		if (no > ni) why("adds markup character " c)
		else if (no < ni) why("drops markup character " c)
	}
	for (i = 1; i <= length(INSERT); i++) {
		c = substr(INSERT, i, 1)
		if (countchar(out, c) < countchar(in_, c)) why("drops markup character " c)
	}

	# W2, as pairing: every added `*`, `` ` `` or `~` must resolve into
	# spans; leftovers are compared against the input's own leftovers.
	split("", SPAN); lin = starscan(in_); em_in = SPAN["em"]; st_in = SPAN["strong"]
	split("", SPAN); lou = starscan(out); em_ou = SPAN["em"]; st_ou = SPAN["strong"]
	if (lou > lin) why("unbalanced *")
	addruns(in_, out, "`"); if (added_runs_bad(1)) why("unbalanced `")
	addruns(in_, out, "~"); if (added_runs_bad(2)) why("unbalanced ~")
	din = int(countchar(in_, "~") / 4)  # each input ~~x~~ is two runs of two
	nspans = em_ou + st_ou + AR[2] / 2 - em_in - st_in - din

	# W5 feeds W4: plain slots take no added formatting and no emoji.
	emojiscan(in_, out)
	if (plainrole(role) && (countchar(out, "*") != countchar(in_, "*") || \
			countchar(out, "`") != countchar(in_, "`") || countchar(out, "~") != countchar(in_, "~") || \
			EMOJI_COUNT > 0))
		why("formatting in a plain slot")

	if (index(out, "![") && !index(in_, "![")) why("adds ![ (renders as image syntax)")
	pj = in_; pk = out; gsub(/[*`~]/, "", pj); gsub(/[*`~]/, "", pk)
	if (index(pk, "!!") && !index(pj, "!!")) why("adds !!")
	if (index(pk, "??") && !index(pj, "??")) why("adds ??")
	if (index(out, "==") && !index(in_, "==")) why("adds ==")
	rest = out
	while (match(rest, /&(#|[A-Za-z])[A-Za-z0-9]*;/)) {
		ent = substr(rest, RSTART, RLENGTH)
		rest = substr(rest, RSTART + RLENGTH)
		if (!index(in_, ent)) { why("adds HTML entity"); break }
	}
	if (out ~ /^[-+*=>#] / || out ~ /^[0-9]+[.)] / || out ~ /^(h[1-6]|p|bq|bc|pre|fn[0-9]+)\. / || \
		out ~ /^---/ || out ~ /^```/ || out ~ /^~~~/)
		why("starts with a block marker")

	L = textlen(in_); O = textlen(out)
	lo = int((L + 1) / 2); hi = (2 * L > L + 40) ? 2 * L : L + 40
	if (O < lo) why("too short: " O " bytes, min " lo)
	if (O > hi) why("too long: " O " bytes, max " hi)
	if (index(role, "one-word") || index(role, "four word")) {
		nw = split(out, words, " ")
		if (nw > 4) why("word-limited role, " nw " words, max 4")
	}

	if (!(tone in MAXPROF)) { why("unknown tone " tone); return }
	tmp = tolower(out); gsub(/[^a-z]+/, " ", tmp); nw = split(tmp, words, " ")
	nprof = 0; nf = 0
	for (i = 1; i <= nw; i++) {
		if (index(PROFANITY, " " words[i] " ")) nprof++
		if (index(FWORDS, " " words[i] " ")) nf++
	}
	if (nprof > MAXPROF[tone]) why(tone ": " nprof " profanity words, max " MAXPROF[tone])
	if (tone == "spicy" && nf > 0) why("spicy: f-word")
	ncaps = 0
	for (t in FO) if (FO[t] == "acronym" && !hasword(in_, t)) ncaps++
	if (ncaps > MAXCAPS[tone]) why(tone ": " ncaps " new all-caps words, max " MAXCAPS[tone])
	tmp = out; nbang = gsub(/!/, "", tmp)
	if (nbang > MAXBANG[tone]) why(tone ": " nbang " exclamation marks, max " MAXBANG[tone])
	if (nspans > MAXSPANS[tone]) why(tone ": " nspans " formatting spans, max " MAXSPANS[tone])
	if (tone == "mild" && (st_ou - st_in) + (AR[2] / 2 - din) > 0) why("mild: only *italic*")
	if (EMOJI_COUNT > MAXEMOJI[tone]) why(tone ": " EMOJI_COUNT " emoji, max " MAXEMOJI[tone])
}

# ---- mode=check: examples/, mock/, testdata/ -------------------------------

function bad(loc, msg) { print "FAIL " loc ": " msg; NBAD++ }
function warn(loc, msg) { print "WARN " loc ": " msg; NWARN++ }

mode == "check" && FILENAME ~ /\.sample\.json$/ { SAMPLE = SAMPLE $0 "\n"; next }

mode == "check" {
	if ($0 ~ /^[ \t\r]*$/) next
	if (FILENAME ~ /\/examples\/[^\/]*$/) kind = "examples"
	else if (FILENAME ~ /\/mock\/[^\/]*$/) kind = "mock"
	else if (FILENAME ~ /\/testdata\/[^\/]*$/) kind = "testdata"
	else { bad(FILENAME ":" FNR, "not under examples/, mock/ or testdata/"); next }
	base = FILENAME; sub(/^.*\//, "", base); sub(/\.jsonl$/, "", base)
	loc = kind "/" base ".jsonl:" FNR

	if (jparse($0) < 0) { bad(loc, "bad JSON: " JERR); next }
	for (k in J)
		if (!(k in REQ) && !(kind == "testdata" && (k == "tone" || k == "expect"))) { bad(loc, "unknown key " k); next }
	missing = ""
	for (k in REQ) if (!(k in J)) missing = missing " " k
	if (kind == "testdata" && !("tone" in J)) missing = missing " tone"
	if (kind == "testdata" && !("expect" in J)) missing = missing " expect"
	if (missing != "") { bad(loc, "missing keys:" missing); next }

	tone = (kind == "testdata") ? J["tone"] : base
	guard(tone, J["field_role"], J["input"], J["output"])

	if (kind == "testdata") {
		ncase++
		if (REASONS != "" && index(REASONS, J["expect"])) caught++
		else bad(loc, "selftest wanted a failure containing \"" J["expect"] "\", got: " (REASONS == "" ? "pass" : REASONS))
		next
	}
	if (kind == "examples" && index(SAMPLE, "\"" JR["input"] "\""))
		why("input copies a data/*.sample.json value; examples must use other subjects")
	if (REASONS != "") bad(loc " " J["field"], REASONS)
	if (kind == "mock" && !index(SAMPLE, "\"" JR["input"] "\""))
		warn(loc " " J["field"], "input is not a data/*.sample.json value; this mock reply is stale")

	n = ++COUNT[kind, tone]
	SEQ[kind, tone, n] = J["template"] SUBSEP J["field"] SUBSEP J["field_role"] SUBSEP J["input"]
	TOTAL[kind]++
	next
}

# ---- mode=system: system.md, <tone>.md, examples/<tone>.jsonl --------------

mode == "system" {
	if (FNR == 1) part++
	if (part == 1) { SYS = SYS $0 "\n"; next }
	if (part == 2) { TONE = TONE $0 "\n"; next }
	if ($0 ~ /^[ \t\r]*$/) next
	if (jparse($0) < 0) {
		print "assemble: " FILENAME ":" FNR ": " JERR > "/dev/stderr"
		ERR = 1
		exit 2
	}
	EX = EX "\n\nField: " J["field"] "\nRole: " J["field_role"] "\nInput: " J["input"] "\nOutput: " J["output"]
	next
}

END {
	if (ERR) exit 2
	if (mode == "system") {
		sub(/[ \t\r\n]+$/, "", SYS); sub(/[ \t\r\n]+$/, "", TONE)
		printf "%s\n\n%s\n\n## Examples%s", SYS, TONE, EX
		exit 0
	}
	for (kk = 1; kk <= 2; kk++) {
		kind = (kk == 1) ? "examples" : "mock"
		min = (kind == "examples") ? MINEX : 1
		for (i = 1; i <= 3; i++)
			if (COUNT[kind, TONES[i]] < min)
				bad(kind "/" TONES[i] ".jsonl", (COUNT[kind, TONES[i]] + 0) " entries, need at least " min)
		for (i = 2; i <= 3; i++) {
			tone = TONES[i]
			if (COUNT[kind, tone] != COUNT[kind, "mild"]) { bad(kind "/" tone ".jsonl", "entry count differs from mild"); continue }
			for (j = 1; j <= COUNT[kind, "mild"]; j++)
				if (SEQ[kind, tone, j] != SEQ[kind, "mild", j])
					bad(kind "/" tone ".jsonl entry " j, "template, field, field_role or input differs from mild")
		}
	}
	printf "voice check: %d examples, %d mock replies, %d/%d selftest breaks caught, %d warnings, %d failures\n", \
		TOTAL["examples"], TOTAL["mock"], caught, ncase, NWARN, NBAD
	exit (NBAD > 0) ? 1 : 0
}
