/*******************************************************************************
 * コマンドライン引数のパーサー
 * 
 * getoptと同じくコマンドラインの解析を行う。
 * getoptとの違いは、getoptは関数の引数に基づいて引数の解析を行うが、
 * 本モジュールの parseOptions は、構造体の変数を引数に取ることで、構造体メンバ
 * に関連付けられたUDAによりコマンドライン引数の解析を行う。
 * 
 *------------------------------------------------------------------------------
 *@help("Help messages for heading of application.\n")
 *struct Dat
 *{
 *  @help("Description of `value`")
 *  string value;
 *  
 *  string nonHelpedValue;
 *  
 *  @ignore
 *  string ignoredValue;
 *  
 *  @opt("a|aaaa") @help("Description of `i32value`")
 *  int i32value;
 *  
 *  @opt("f|ff")
 *  int f32value;
 *}
 *------------------------------------------------------------------------------
 * 
 * 構造体(型)に付与できるUDAは以下の通り
 * 
 * - help(str) : アプリケーションのヘルプメッセージ
 * - caseSensitive : コマンドライン引数の大文字小文字を区別するかどうか。デフォルトは区別しない。
 * - passThrough : 解釈されなかったコマンドライン引数を無視するか例外としてはじくか。デフォルトは例外としてはじく。
 * - binding : 短いコマンドライン引数を、まとめて指定できるか(`-abc`で`-a -b -c`と同じ解釈にさせるかどうか)
 * - assignChar(str) : コマンドライン引数の「割り当て」に使用する文字を指定できる。(デフォルトは`=`。`-a=xxx` や `--arg=xxx` など。区切り文字を変更可能。)
 * - arraySeparator(str) : コマンドライン引数の配列の区切り文字を指定できる。(デフォルトは`,`(カンマ)。`-a=xxx,yyy,zzz`の`,`を変更可能。)
 * - endOfOptions(str) : コマンドライン引数として解釈させる最後の文字を指定できる。(デフォルトは`--`で、`-a=xxx -b=yyy -- -c=zzz`では、`-a`と`-b`だけ解釈させる区切り文字として作用する。この区切り文字を変更可能。)
 * - shortOpt(str) : 短いコマンドライン引数として解釈させるprefixを指定できる。(デフォルトは`-`。`-a`などのように使われる。)
 * - longOpt(str) : 短いコマンドライン引数として解釈させるprefixを指定できる。(デフォルトは`--`。`--arg`などのように使われる。)
 * 
 * 構造体メンバーに付与できるUDAは以下の通り
 * 
 * - help(str) : 引数のヘルプメッセージ
 * - opt(str) : 引数。`"a|args"` とすることで、`-a`と`--args`を同時に定義可能。指定しなければオプションとして指定できない。
 * - required : 引数を指定することを必須化する。デフォルトは`false`。
 * - convBy!fn : 指定した関数`fn`によって引数の値をメンバ変数の型に変換する。
 * - ignore : 指定したメンバーをコマンドライン引数の解釈に使用しない。
 * 
 * コマンドライン引数の解釈の対象となるメンバーの型は以下の通り。※リストの上のものほど優先度が高い。
 * 
 * - convByが指定されている引数
 *   - T function(string arg)
 *   - void function(ref T dst, string arg)
 *   - void function(out T dst, string arg)
 *   - void function(in S dat, ref T dst, string arg)
 *   - void function(in S dat, out T dst, string arg)
 *   - void function(ref S dat, string arg)
 * - bool : 真偽値
 * - string : 文字列型
 * - T[] : 配列。std.conv.toにより、文字列がTに変換可能。
 * - V[K] : 連想配列。std.conv.toにより文字列がV, Kに変換可能。
 * - T : std.conv.toにより、文字列がTに変換可能。
 * - void function(bool shortPrefix, string arg)
 * - void function(string prefix, string arg)
 * - void function(string arg)
 * - void function(bool enabled)
 * - void function()
 */
module voile.parseopt;

import std.traits, std.meta;

private:
struct Help
{
	string help;
}


struct CaseSensitive
{
}
struct PassThrough
{
}
struct Binding
{
}
struct AssignChar
{
	dchar assignChar;
}
struct ArraySeparator
{
	dchar arraySeparator;
}

struct EndOfOptions
{
	string endOfOptions;
}

struct OptShort
{
	string[] optShort;
}
struct OptLong
{
	string[] optLong;
}

struct OptPrefix
{
	enum Type { none, shortOpt, longOpt }
	Type   type;
	string prefix;
}

OptPrefix[] sortPrefix(string[] shortOpt, string[] longOpt) pure @safe
{
	import std.algorithm, std.array, std.range;
	auto chained = chain(
		longOpt.map!(a => OptPrefix(OptPrefix.Type.longOpt, a)),
		shortOpt.map!(a => OptPrefix(OptPrefix.Type.shortOpt, a))).array;
	chained.sort!((a, b)=> a.prefix.length > b.prefix.length, SwapStrategy.stable);
	return chained;
}

@safe unittest
{
	alias sp = OptPrefix.Type.shortOpt;
	alias lp = OptPrefix.Type.longOpt;
	static assert(sortPrefix(["-"], ["--"])
		== [OptPrefix(lp, "--"), OptPrefix(sp, "-")]);
}



struct TypeOption
{
	string   help;
	bool     caseSensitive;
	bool     passThrough;
	bool     binding;
	dchar    assignChar;
	dchar    arraySeparator;
	string   endOfOptions;
	string[] optShort;
	string[] optLong;
}


template getUDA(alias T, OptType, string memberName)
{
	alias ValType = typeof(__traits(getMember, OptType, memberName));
	template get(UDAType, ValType defaultVal, string udaMemberName = memberName)
	{
		static if (hasUDA!(T, OptType))
		{
			enum get = __traits(getMember, getUDAs!(T, OptType)[0], memberName);
		}
		else static if (hasUDA!(T, UDAType))
		{
			static if (is(ValType == bool) && !__traits(hasMember, UDAType, memberName))
			{
				enum get = true;
			}
			else
			{
				enum get = __traits(getMember, getUDAs!(T, UDAType)[0], memberName);
			}
		}
		else
		{
			enum get = defaultVal;
		}
	}
}
template TypeOptionOf(T)
{
	enum TypeOptionOf = TypeOption(
		getUDA!(T, TypeOption, "help").get!(           Help,           null),
		getUDA!(T, TypeOption, "caseSensitive").get!(  CaseSensitive,  false),
		getUDA!(T, TypeOption, "passThrough").get!(    PassThrough,    false),
		getUDA!(T, TypeOption, "binding").get!(        Binding,        false),
		getUDA!(T, TypeOption, "assignChar").get!(     AssignChar,     '='),
		getUDA!(T, TypeOption, "arraySeparator").get!( ArraySeparator, ','),
		getUDA!(T, TypeOption, "endOfOptions").get!(   EndOfOptions,   "--"),
		getUDA!(T, TypeOption, "optShort").get!(       OptShort,       ["-"]),
		getUDA!(T, TypeOption, "optLong").get!(        OptLong,        ["--"])
	);
}

@safe unittest
{
	@help("xxx_help_xxx")
	struct Dat1{}
	static assert(TypeOptionOf!Dat1.help == "xxx_help_xxx");
	
	@caseSensitive()
	struct Dat2{}
	static assert(!TypeOptionOf!Dat1.caseSensitive);
	static assert(TypeOptionOf!Dat2.caseSensitive);
	
	@passThrough()
	struct Dat3{}
	static assert(!TypeOptionOf!Dat3.caseSensitive);
	static assert(TypeOptionOf!Dat3.passThrough);
	
	@assignChar(':')
	@arraySeparator()
	struct Dat4{}
	static assert(!TypeOptionOf!Dat4.passThrough);
	static assert(TypeOptionOf!Dat4.assignChar == ':');
	static assert(TypeOptionOf!Dat4.arraySeparator == ',');
	
	@assignChar()
	@arraySeparator('|')
	struct Dat5{}
	static assert(TypeOptionOf!Dat5.assignChar == '=');
	static assert(TypeOptionOf!Dat5.arraySeparator == '|');
	
	@typeOption("xxxTESTxxx")
	struct Dat6{}
	static assert(TypeOptionOf!Dat6.help == "xxxTESTxxx");
}


struct Opt
{
	string option;
}

struct Req
{
}

struct ConvBy(alias fn)
{
}

// isXXXX
enum bool isConvBy(alias uda) = isInstanceOf!(ConvBy, uda);
// hasXXXX
enum bool hasConvBy(alias symbol) = Filter!(isConvBy, __traits(getAttributes, symbol)).length > 0;
// getXXXX
template getConvBy(alias value)
{
	static if (isConvBy!value)
	{
		// UDAから関数を取り出す
		alias getConvBy = TemplateArgsOf!value[0];
	}
	else
	{
		// シンボルからUDAを取り出す
		alias uda = Filter!(isConvBy, __traits(getAttributes, value))[0];
		// UDAから関数を取り出す
		alias getConvBy = TemplateArgsOf!uda[0];
	}
}



struct Ignore
{
}

// isXXXX
enum bool isIgnore(alias uda) = is(uda : Ignore);
// hasXXXX
enum bool hasIgnore(alias symbol) = Filter!(isIgnore, __traits(getAttributes, symbol)).length > 0;


struct Option
{
	string option;
	string help;
	bool   required;
	
	dchar[] shortOptions() const @property
	{
		import std.algorithm, std.array;
		return option.splitter('|').filter!(a => a.length == 1).map!(a=>cast(dchar)a[0]).array;
	}
	string[] longOptions() const @property
	{
		import std.algorithm, std.array;
		return option.splitter('|').filter!(a => a.length > 1).array;
	}
	
}

template OptionOf(alias Type, string memberName)
{
	enum OptionOf = Option(
		getUDA!(__traits(getMember, Type, memberName), Option, "option").get!(  Opt,  null),
		getUDA!(__traits(getMember, Type, memberName), Option, "help").get!(    Help, null),
		getUDA!(__traits(getMember, Type, memberName), Option, "required").get!(Req,  false)
	);
}

@safe unittest
{
	struct Dat1{
		@opt("xxx_opt_xxx")
		string m1;
		@opt("aaa") @help("xxxxxx")
		string m2;
		@option("bbb", "yyyyyy")
		string m3;
		@ignore
		string m4;
	}
	static assert(OptionOf!(Dat1, "m1").option == "xxx_opt_xxx");
	static assert(OptionOf!(Dat1, "m2").option == "aaa");
	static assert(OptionOf!(Dat1, "m2").help   == "xxxxxx");
	static assert(OptionOf!(Dat1, "m3").option == "bbb");
	static assert(OptionOf!(Dat1, "m3").help   == "yyyyyy");
	static assert(OptionOf!(Dat1, "m4").help   == "");
	static assert(OptionOf!(Dat1, "m4").option == "");
}

void assignData(string memberName, T)(ref T dat, OptPrefix prefix, string arg) @safe
{
	import std.conv, std.exception, std.array;
	alias MemberType = typeof(__traits(getMember, dat, memberName));
	static if (hasIgnore!(__traits(getMember, dat, memberName)))
	{
		// 何もしない
	}
	else static if (hasConvBy!(__traits(getMember, dat, memberName)))
	{
		// convByで変換用の関数が指定されている
		alias proxyFunc = getConvBy!(__traits(getMember, dat, memberName));
		static if (__traits(compiles, {__traits(getMember, dat, memberName) = proxyFunc(arg);}))
		{
			__traits(getMember, dat, memberName) = proxyFunc(arg);
		}
		else static if (__traits(compiles, {proxyFunc(__traits(getMember, dat, memberName), arg);}))
		{
			proxyFunc(__traits(getMember, dat, memberName), arg);
		}
		else static if (__traits(compiles, {proxyFunc(dat, arg);}))
		{
			proxyFunc(dat, arg);
		}
		else
		{
			static assert(0, "Invalid convBy function.");
		}
	}
	else static if (is(MemberType == bool))
	{
		// 真偽値
		__traits(getMember, dat, memberName) =
			arg.length == 0 ? true : to!MemberType(arg);
	}
	else static if (is(MemberType == string))
	{
		// 文字列
		__traits(getMember, dat, memberName) = arg;
	}
	else static if (is(MemberType == U[], U))
	{
		// 配列
		auto typeOpt = TypeOptionOf!T;
		if (arg.length == 0)
		{
			__traits(getMember, dat, memberName) = null;
		}
		else if (arg.length >= 2 && arg[0] == '[' && arg[$-1] == ']')
		{
			__traits(getMember, dat, memberName) = to!MemberType(arg);
		}
		else
		{
			auto splitted = arg.split(typeOpt.arraySeparator);
			if (splitted.length > 1)
			{
				foreach (a; splitted)
					__traits(getMember, dat, memberName) ~= to!U(a);
			}
			else
			{
				__traits(getMember, dat, memberName) ~= to!U(arg);
			}
		}
	}
	else static if (is(MemberType == V[K], K, V))
	{
		// 連想配列
		auto typeOpt = TypeOptionOf!T;
		if (arg.length == 0)
		{
			__traits(getMember, dat, memberName) = null;
		}
		else if (arg.length >= 2 && arg[0] == '[' && arg[$-1] == ']')
		{
			__traits(getMember, dat, memberName) = to!MemberType(arg);
		}
		else
		{
			void set(string kvStr)
			{
				auto kv = kvStr.split(typeOpt.assignChar);
				if (kv.length == 2)
				{
					auto k = kv[0].to!K;
					if (kv[1].length == 0)
					{
						if (k in __traits(getMember, dat, memberName))
							__traits(getMember, dat, memberName).remove(k);
					}
					else
						__traits(getMember, dat, memberName)[k] = kv[1].to!V;
				}
				else
					__traits(getMember, dat, memberName)[kvStr.to!K] = V.init;
			}
			auto splitted = arg.split(typeOpt.arraySeparator);
			if (splitted.length > 1)
			{
				foreach (a; splitted)
					set(a);
			}
			else
			{
				set(arg);
			}
		}
	}
	else static if (__traits(compiles, to!MemberType(arg)))
	{
		// 変換可能
		__traits(getMember, dat, memberName) = to!MemberType(arg);
	}
	else static if (isCallable!(__traits(getMember, dat, memberName)))
	{
		static if (__traits(compiles, __traits(getMember, dat, memberName)(
			prefix.type == OptPrefix.Type.shortOpt, arg)))
		{
			// void function(bool shortPrefix, string arg)
			__traits(getMember, dat, memberName)(
				prefix.type == OptPrefix.Type.shortOpt, arg);
		}
		else static if (__traits(compiles, __traits(getMember, dat, memberName)(prefix.prefix, arg)))
		{
			// void function(string prefix, string arg)
			__traits(getMember, dat, memberName)(prefix.prefix, arg);
		}
		else static if (__traits(compiles, __traits(getMember, dat, memberName)(arg)))
		{
			// void function(string arg)
			__traits(getMember, dat, memberName)(arg);
		}
		else static if (__traits(compiles, __traits(getMember, dat, memberName)(true)))
		{
			// void function(bool enabled)
			__traits(getMember, dat, memberName)(
				arg.length == 0 ? true : arg.to!bool());
		}
		else static if (__traits(compiles, __traits(getMember, dat, memberName)()))
		{
			// void function()
			__traits(getMember, dat, memberName)();
		}
		else
		{
			static assert(0, "Cannot solve argument.");
		}
	}
	else
	{
		static assert(0, "Cannot solve argument.");
	}
}

@safe unittest
{
	import std.math;
	auto prefixLong1  = OptPrefix(OptPrefix.Type.longOpt,  "--");
	auto prefixLong2  = OptPrefix(OptPrefix.Type.longOpt,  "/");
	auto prefixShort1 = OptPrefix(OptPrefix.Type.shortOpt, "-");
	auto prefixShort2 = OptPrefix(OptPrefix.Type.shortOpt, "/");
	struct Dat
	{
		string arg;
		bool   enabled;
		int    i32Dat;
		float  f32Dat;
		string[]       ary1;
		uint[]         ary2;
		string[string] aa1;
		uint[string]   aa2;
		float[uint]    aa3;
		void foo1() { enabled = true; }
		void foo2(bool b) { enabled = b; }
		void foo3(string x) { arg = x; }
		void foo4(string prefix, string x) in(prefix == "--") { arg = x; }
		void foo5(string prefix, string x) in(prefix == "-")  { arg = x; }
	}
	Dat dat;
	dat.assignData!"arg"(prefixLong1, "xxx");
	assert(dat.arg == "xxx");
	dat.assignData!"enabled"(prefixLong1, "true");
	assert(dat.enabled == true);
	dat.assignData!"enabled"(prefixLong1, "false");
	assert(dat.enabled == false);
	dat.assignData!"enabled"(prefixLong1, "");
	assert(dat.enabled == true);
	dat.assignData!"i32Dat"(prefixLong1, "512");
	assert(dat.i32Dat == 512);
	dat.assignData!"f32Dat"(prefixLong1, "12.5e-2");
	assert(dat.f32Dat == 12.5e-2f);
	
	dat.assignData!"ary1"(prefixLong1, "aaa");
	assert(dat.ary1 == ["aaa"]);
	dat.assignData!"ary1"(prefixLong1, "");
	assert(dat.ary1.length == 0);
	dat.assignData!"ary1"(prefixLong1, "aaa");
	dat.assignData!"ary1"(prefixLong1, "bbb");
	assert(dat.ary1 == ["aaa", "bbb"]);
	dat.assignData!"ary1"(prefixLong1, "ccc,ddd");
	assert(dat.ary1 == ["aaa", "bbb", "ccc", "ddd"]);
	dat.assignData!"ary1"(prefixLong1, `["xxx", "yyy", "zzz"]`);
	assert(dat.ary1 == ["xxx", "yyy", "zzz"]);
	
	dat.assignData!"ary2"(prefixLong1, "12");
	dat.assignData!"ary2"(prefixLong1, "1,2");
	dat.assignData!"ary2"(prefixLong1, "3");
	assert(dat.ary2 == [12,1,2,3]);
	dat.assignData!"ary2"(prefixLong1, "");
	assert(dat.ary2.length == 0);
	dat.assignData!"ary2"(prefixLong1, "1");
	dat.assignData!"ary2"(prefixLong1, `[111, 222, 333]`);
	assert(dat.ary2 == [111, 222, 333]);
	
	dat.assignData!"aa1"(prefixLong1, "aa=aaa");
	dat.assignData!"aa1"(prefixLong1, "bb=bbb,cc=ccc");
	dat.assignData!"aa1"(prefixLong1, "dd=ddd");
	assert(dat.aa1["aa"] == "aaa");
	assert(dat.aa1["bb"] == "bbb");
	assert(dat.aa1["cc"] == "ccc");
	assert(dat.aa1["dd"] == "ddd");
	dat.assignData!"aa1"(prefixLong1, "aa=");
	assert("aa" !in dat.aa1);
	assert("bb" in dat.aa1);
	dat.assignData!"aa1"(prefixLong1, "aa");
	assert("aa" in dat.aa1);
	assert(dat.aa1["aa"].length == 0);
	dat.assignData!"aa1"(prefixLong1, "");
	assert(dat.aa1 is null);
	dat.assignData!"aa1"(prefixLong1, "aa=aaa");
	dat.assignData!"aa1"(prefixLong1, `["xx":"xxx", "yy":"yyy", "zz":"zzz"]`);
	assert(dat.aa1["xx"] == "xxx");
	assert(dat.aa1["yy"] == "yyy");
	assert(dat.aa1["zz"] == "zzz");
	
	dat.assignData!"aa2"(prefixLong1, "aa=111");
	dat.assignData!"aa2"(prefixLong1, "bb=222,cc=333");
	dat.assignData!"aa2"(prefixLong1, "dd=444");
	assert(dat.aa2["aa"] == 111);
	assert(dat.aa2["bb"] == 222);
	assert(dat.aa2["cc"] == 333);
	assert(dat.aa2["dd"] == 444);
	dat.assignData!"aa2"(prefixLong1, "aa=");
	assert("aa" !in dat.aa2);
	assert("bb" in dat.aa2);
	dat.assignData!"aa2"(prefixLong1, "aa");
	assert("aa" in dat.aa2);
	assert(dat.aa2["aa"] == 0);
	dat.assignData!"aa2"(prefixLong1, "");
	assert(dat.aa2 is null);
	dat.assignData!"aa2"(prefixLong1, "aa=1");
	dat.assignData!"aa2"(prefixLong1, `["xx":111, "yy":222, "zz":333]`);
	assert(dat.aa2["xx"] == 111);
	assert(dat.aa2["yy"] == 222);
	assert(dat.aa2["zz"] == 333);
	
	dat.assignData!"aa3"(prefixLong1, "2=4.0");
	dat.assignData!"aa3"(prefixLong1, "3=8.0,4=16.0");
	dat.assignData!"aa3"(prefixLong1, "5=32.0");
	assert(dat.aa3[2] == 4.0f);
	assert(dat.aa3[3] == 8.0f);
	assert(dat.aa3[4] == 16.0f);
	assert(dat.aa3[5] == 32.0f);
	dat.assignData!"aa3"(prefixLong1, "2=");
	assert(2 !in dat.aa3);
	assert(3 in dat.aa3);
	dat.assignData!"aa3"(prefixLong1, "2");
	assert(2 in dat.aa3);
	assert(dat.aa3[2].isNaN);
	dat.assignData!"aa3"(prefixLong1, "");
	assert(dat.aa3 is null);
	dat.assignData!"aa3"(prefixLong1, "2=0.5");
	dat.assignData!"aa3"(prefixLong1, `[2:0.5, 3:0.25, 4:0.125]`);
	assert(dat.aa3[2] == 0.5f);
	assert(dat.aa3[3] == 0.25f);
	assert(dat.aa3[4] == 0.125f);
	
	dat.enabled = false;
	dat.assignData!"foo1"(prefixLong1, "");
	assert(dat.enabled);
	
	dat.enabled = false;
	dat.assignData!"foo2"(prefixLong1, "true");
	assert(dat.enabled);
	dat.assignData!"foo2"(prefixLong1, "false");
	assert(!dat.enabled);
	
	dat.assignData!"foo3"(prefixLong1, "asdf");
	assert(dat.arg == "asdf");
	
	dat.assignData!"foo4"(prefixLong1, "qwer");
	assert(dat.arg == "qwer");
	
	dat.assignData!"foo5"(prefixShort1, "zcxv");
	assert(dat.arg == "zcxv");
}

template getHelpString(T, size_t displayWidth = 80)
{
	string get() pure @safe
	{
		import std.algorithm, std.array, std.range, std.string, std.conv;
		enum TypeOption typeOpt = TypeOptionOf!T;
		enum helpStrHead = (typeOpt.help ~ "\n").splitLines.map!(a => a.wrap(displayWidth)).join();
		string helpStr = helpStrHead;
		
		string[] optLongs;
		enum hasHelp(string memberName)    = OptionOf!(T, memberName).help.length > 0;
		enum getAllMembers(T)              = Filter!(hasHelp, __traits(allMembers, T));
		enum getOption(string memberName)  = OptionOf!(T, memberName);
		enum getHelp(string memberName)    = getOption!memberName.help;
		enum getOpts(string memberName)    = getOption!memberName.longOptions.length > 0
			? getOption!memberName.longOptions[0]
			: memberName;
		enum helpStrings                   = [staticMap!(getHelp,   getAllMembers!T)] ~ ["Display this help message."];
		enum optNames                      = [staticMap!(getOpts,   getAllMembers!T)] ~ ["help"];
		enum optNamesMaxLen                = optNames.maxElement().length;
		enum optShortPrefix = typeOpt.optShort[0];
		enum optLongPrefix  = typeOpt.optLong[0];
		
		static assert(optNames.length == helpStrings.length);
		static assert([getAllMembers!T].length + 1 == helpStrings.length);
		
		static foreach (i, memberName; [getAllMembers!T])
		{{
			enum sOp = getOption!(memberName).shortOptions;
			enum lOp = optNames[i];
			enum shortOpt = sOp.length > 0 ? optShortPrefix ~ to!string([sOp[0]]) : "  ";
			enum longOpt  = optLongPrefix ~ lOp;
			enum optLen   = 1 + shortOpt.length + 1 + optLongPrefix.length + optNamesMaxLen + 1;
			enum helpLen  = displayWidth - optLen;
			enum valHelpLines = helpStrings[i].wrap(helpLen).splitLines();
			enum valFirstLine = " " ~ shortOpt
				~ " " ~ longOpt.leftJustify(optLongPrefix.length + optNamesMaxLen)
				~ " " ~ valHelpLines[0];
			enum valFllowingLines = valHelpLines[1..$].map!(a => " ".repeat(optLen).join ~ a).array;
			enum valHelpLinesJoined = join([valFirstLine] ~ valFllowingLines, "\n");
			helpStr ~= valHelpLinesJoined ~ "\n";
		}}
		
		{
			// -h --help
			enum optLen   = 1 + optShortPrefix.length + 1 + 1 + optLongPrefix.length + optNamesMaxLen + 1;
			enum helpLen  = displayWidth - optLen;
			enum valHelpLines = helpStrings[$-1].wrap(helpLen).splitLines();
			enum valFirstLine = " " ~ optShortPrefix ~ "h"
				~ " " ~ optLongPrefix ~ "help".leftJustify(optNamesMaxLen)
				~ " " ~ valHelpLines[0];
			enum valFllowingLines = valHelpLines[1..$].map!(a => " ".repeat(optLen).join ~ a).array;
			enum valHelpLinesJoined = join([valFirstLine] ~ valFllowingLines, "\n");
			helpStr ~= valHelpLinesJoined;
		}
		return helpStr;
	}
	enum string getHelpString = get();
}

@safe unittest
{
	import std.string;
	@help("aaaaa bbbbb ccccc ddddd eeeee fffff ggggg hhhhh iiiii jjjjj kkkkk lllll mmmmm "
		~ "nnnnn ooooo ppppp.\n")
	struct Dat
	{
		@help("xxx")
		string value;
		
		string nonHelpedValue;
		
		@opt("a|aaaa") @help("xxxxi32valxxxx")
		int i32value;
		
		@opt("f|ff")
		@help("qqqqq aaaaa wwwww sssss eeeee ddddd rrrrr fffff ttttt ggggg yyyyy "
			~"hhhhh uuuuu jjjjj iiiii kkkkk.")
		int f32value;
	}
	string helpStr;
	helpStr = getHelpString!Dat;
	assert(helpStr.length > 0);
	assert(helpStr == `
		aaaaa bbbbb ccccc ddddd eeeee fffff ggggg hhhhh iiiii jjjjj kkkkk lllll mmmmm
		nnnnn ooooo ppppp.
		
		    --value xxx
		 -a --aaaa  xxxxi32valxxxx
		 -f --ff    qqqqq aaaaa wwwww sssss eeeee ddddd rrrrr fffff ttttt ggggg yyyyy
		            hhhhh uuuuu jjjjj iiiii kkkkk.
		 -h --help  Display this help message.
		`.chompPrefix("\n").outdent.chomp);
}

public:

/// 
Help help(string str) pure nothrow @nogc @safe
{
	return Help(str);
}

///
CaseSensitive caseSensitive() pure nothrow @nogc @safe
{
	return CaseSensitive.init;
}

///
PassThrough passThrough() pure nothrow @nogc @safe
{
	return PassThrough.init;
}

///
Binding binding() pure nothrow @nogc @safe
{
	return Binding.init;
}

///
AssignChar assignChar(dchar c = '=') pure nothrow @nogc @safe
{
	return AssignChar(c);
}
///
ArraySeparator arraySeparator(dchar c = ',') pure nothrow @nogc @safe
{
	return ArraySeparator(c);
}

///
EndOfOptions endOfOptions(string str)
{
	return EndOfOptions(str);
}

///
Opt opt(string str) pure nothrow @nogc @safe
{
	return Opt(str);
}

///
Req required() pure nothrow @nogc @safe
{
	return Req.init;
}

///
OptShort optShort(string[] str...) pure nothrow @nogc @safe
{
	return OptShort(str);
}

///
OptLong optLong(string[] str...) pure nothrow @nogc @safe
{
	return OptLong(str);
}

///
alias convBy(alias fn) = ConvBy!fn;

///
alias ignore = Ignore;

///
TypeOption typeOption(
	string   help           = null,
	bool     caseSensitive  = false,
	bool     passThrough    = false,
	bool     binding        = false,
	dchar    assignChar     = '=',
	dchar    arraySeparator = ',',
	string   endOfOptions   = "--",
	string[] shortOpt       = ["-"],
	string[] longOpt        = ["--"]) pure nothrow @nogc @safe
{
	return TypeOption(
		help, caseSensitive, passThrough, binding, assignChar,
		arraySeparator, endOfOptions, shortOpt, longOpt);
}

///
Option option(
	string opt,
	string help    = null,
	bool required  = false) pure nothrow @nogc @safe
{
	return Option(opt, help, required);
}

///
class ParseOptException: Exception
{
	import std.exception: basicExceptionCtors;
	mixin basicExceptionCtors;
}


///
struct HelpInformation
{
	///
	string help;
	
	///
	bool wanted;
	
	///
	T opCast(T)() pure nothrow @nogc const
	if (is(T == bool))
	{
		return wanted;
	}
}

private struct ArgData
{
	size_t[]  idx;
	OptPrefix prefix;
	string    key;
	string    data;
}

// step1: 
private ArgData[] _parseArgsStep1(string[] args,
	in ref TypeOption typeOpt, in ref OptPrefix[] optPrefices) pure @safe
{
	import std.algorithm, std.string;
	ArgData[] ret;
	// 引数をプリフィックスとアサインの記号で分類
	for (size_t i = 1; i < args.length; ++i)
	{
		auto idxPrefix = optPrefices.countUntil!(a => args[i].startsWith(a.prefix));
		auto foundPrefix = idxPrefix < optPrefices.length;
		if (foundPrefix)
		{
			// prefix matched
			auto optPrefix   = optPrefices[idxPrefix];
			auto arg         = args[i][optPrefix.prefix.length..$];
			if (arg.length > 0)
			{
				if (optPrefix.type == OptPrefix.Type.shortOpt
					&& !typeOpt.binding)
				{
					if (arg.length > 2 && arg[1] == typeOpt.assignChar)
					{
						ret ~= ArgData([i], optPrefix, arg[0..1], arg[2..$]);
					}
					else
					{
						string optArg    = arg.length > 1 ? arg[0 .. 1] : arg;
						string assignArg = arg.length > 1 ? arg[1 .. $] : null;
						ret ~= ArgData([i], optPrefix, optArg, assignArg);
					}
				}
				else
				{
					auto idxSep      = arg.countUntil(typeOpt.assignChar);
					auto foundSep    = idxSep < arg.length;
					string optArg    = foundSep ? arg[0 .. idxSep]   : arg;
					string assignArg = foundSep ? arg[idxSep+1 .. $] : null;
					ret ~= ArgData([i], optPrefix, optArg, assignArg);
				}
			}
			else
			{
				ret ~= ArgData([i], optPrefix, null, null);
			}
		}
		else if (args[i] != typeOpt.endOfOptions)
		{
			// non-prefix
			ret ~= ArgData([i], OptPrefix.init, args[i], null);
		}
		else
		{
			// end of options
			break;
		}
	}
	return ret;
}

// step2
private ArgData[] _parseArgsStep2(ArgData[] args, string[] boolArgs) pure @safe
{
	import std.algorithm;
	ArgData[] ret;
	for (size_t i = 0; i < args.length; ++i)
	{
		if (args[i].prefix.type != OptPrefix.Type.none)
		{
			// prefix
			if (args[i].data is null
				&& (i + 1 < args.length)
				&& args[i + 1].prefix.type == OptPrefix.Type.none
				&& !boolArgs.canFind!(a => args[i].key))
			{
				// アサイン記号がなくて、次の引数にプリフィックスがなく、bool型でもない
				ret ~= ArgData(args[i].idx ~ args[i + 1].idx, args[i].prefix, args[i].key, args[i + 1].key);
				++i;
				continue;
			}
		}
		else
		{
			// none prefix
			// pass-through
		}
		ret ~= args[i];
	}
	return ret;
}

///
HelpInformation parseOptions(T)(ref string[] args, ref T dat) pure @safe
{
	import std.algorithm, std.array, std.exception, std.conv;
	enum TypeOption typeOptData = TypeOptionOf!T;
	enum optPreficesDat = sortPrefix(typeOptData.optShort, typeOptData.optLong);
	static immutable typeOpt = typeOptData;
	static immutable optPrefices = optPreficesDat;
	string[] passedArgs = [args[0]];
	bool helpWanted;
	
	
	enum getOption(string name)        = OptionOf!(T, name);
	enum isRequired(string name)       = getOption!name.required;
	enum isBoolMember(string name)     = is(typeof(__traits(getMember, T, name)) == bool);
	enum getRequiredMembers(T)         = Filter!(isRequired, __traits(allMembers, T));
	enum getRequiredOptions(T)         = staticMap!(getOption, getRequiredMembers!T);
	enum getBooleanMembers(T)          = Filter!(isBoolMember, __traits(allMembers, T));
	enum getBooleanOptions(T)          = staticMap!(getOption, getBooleanMembers!T);
	enum getOptionArgs(Option[] opt)   = opt.map!(a => a.longOptions ~ a.shortOptions.map!(a => a.to!string).array).join();
	enum getBooleanArgs(T)             = getOptionArgs!([getBooleanOptions!T]);
	auto requiredOptions               = [getRequiredOptions!T];
	
	ArgData[] argData;
	argData = _parseArgsStep1(args, typeOpt, optPrefices);
	argData = _parseArgsStep2(argData, getBooleanArgs!T);
	
	void assignMember(string memberName)(OptPrefix prefix, string arg, ref bool matched)
	{
		matched = true;
		dat.assignData!memberName(prefix, arg);
		static if (getOption!memberName.required)
			requiredOptions = requiredOptions.remove!(a => a == memberName);
	}
	foreach (arg; argData)
	{
		string passedArg;
		bool argMatched;
		if (arg.prefix.type == OptPrefix.Type.shortOpt
			&& typeOpt.binding)
		{
			// short prefix
			foreach (argOne; arg.key)
			{
				bool argOneMached;
				static foreach (memberName; __traits(allMembers, T))
				{{
					enum Option memberOpt = OptionOf!(T, memberName);
					enum dchar[] shortOptions = memberOpt.shortOptions();
					if (shortOptions.canFind(argOne))
						assignMember!memberName(arg.prefix, arg.data, argOneMached);
				}}
				if (!argOneMached && argOne == 'h')
				{
					argOneMached = true;
					helpWanted = true;
				}
				if (!argOneMached)
					passedArg ~= argOne;
			}
			if (typeOpt.passThrough && passedArg.length)
			{
				passedArgs ~= arg.data.length > 0
					? [arg.prefix.prefix ~ passedArg ~ typeOpt.assignChar.to!string ~ arg.data]
					: [arg.prefix.prefix ~ passedArg];
			}
		}
		else if (arg.prefix.type == OptPrefix.Type.shortOpt
			&& !typeOpt.binding)
		{
			// no-binding short prefix
			static foreach (memberName; __traits(allMembers, T))
			{{
				enum memberOpt = OptionOf!(T, memberName);
				enum dchar[] shortOptions = memberOpt.shortOptions();
				static if (shortOptions.length > 0)
				{
					if (shortOptions.canFind(arg.key))
					{
						argMatched = true;
						assignMember!memberName(arg.prefix, arg.data, argMatched);
					}
				}
			}}
			if (!argMatched && arg.key == "h")
			{
				argMatched = true;
				helpWanted = true;
			}
			if (!argMatched)
				passedArgs ~= arg.idx.map!(i => args[i]).array;
		}
		else if (arg.prefix.type == OptPrefix.Type.longOpt)
		{
			static foreach (memberName; __traits(allMembers, T))
			{{
				enum memberOpt = OptionOf!(T, memberName);
				enum string[] longOptions = memberOpt.longOptions();
				static if (longOptions.length > 0)
				{
					if (longOptions.canFind(arg.key))
						assignMember!memberName(arg.prefix, arg.data, argMatched);
				}
				else
				{
					if (memberName == arg.key)
						assignMember!memberName(arg.prefix, arg.data, argMatched);
				}
			}}
			if (!argMatched && arg.key == "help")
			{
				argMatched = true;
				helpWanted = true;
			}
			if (!argMatched)
				passedArgs ~= arg.idx.map!(i => args[i]).array;
		}
		else
		{
			// none prefix
			static foreach (memberName; __traits(allMembers, T))
			{{
				enum memberOpt = OptionOf!(T, memberName);
				enum string[] longOptions = memberOpt.longOptions();
				static if (longOptions.length > 0)
				{
					if (longOptions.canFind(arg.key))
						assignMember!memberName(arg.prefix, arg.data, argMatched);
				}
				else
				{
					if (memberName == arg.key)
						assignMember!memberName(arg.prefix, arg.data, argMatched);
				}
			}}
			if (!argMatched && arg.key == "help")
			{
				argMatched = true;
				helpWanted = true;
			}
			if (!argMatched)
				passedArgs ~= arg.idx.map!(i => args[i]).array;
		}
		// 全部のメンバーをチェックしたけど何も見つからない
		static if (!typeOpt.passThrough)
		{
			argMatched.enforce!ParseOptException("Unrecognized options: "~arg.key);
		}
	}
	enforce!ParseOptException(requiredOptions.length == 0, "Less arguments...");
	return helpWanted
		? HelpInformation(getHelpString!T, true)
		: HelpInformation.init;
}

///
@safe unittest
{
	import std.exception;
	struct Dat
	{
		@opt("a|arg")
		string value;
		
		@opt("b|arg2")
		int intValue;
	}
	Dat dat;
	string[] args;
	args = ["xxx", "-a=vvv"];
	args.parseOptions(dat);
	assert(dat.value == "vvv");
	
	dat = Dat.init;
	args = ["xxx", "-ac=vvv"];
	args.parseOptions(dat);
	assert(dat.value == "c=vvv");
	
	dat = Dat.init;
	args = ["xxx", "-a=vvv", "--arg2=123"];
	args.parseOptions(dat);
	assert(dat.intValue == 123);
}

///
@safe unittest
{
	auto args = ["prog", "--foo", "-b"];
	
	@help("Some information about the program.")
	struct Dat
	{
		@option("foo|f", "Some information about foo.")
		bool foo;
		
		@option("bar|b", "Some help message about bar.")
		bool bar;
	}
	
	Dat dat;
	if (auto helpWanted = args.parseOptions(dat))
	{
		import std.stdio;
		writeln(helpWanted.help);
		assert(0);
	}
	
	assert(dat.foo);
	assert(dat.bar);
}

///
@safe unittest
{
	import std.exception : assertThrown;
	string[] args = ["program", "-a"];
	@passThrough
	struct Dat
	{
		@(.opt("a"))
		bool opt;
	}
	Dat dat;
	args.parseOptions(dat);
	assert(dat.opt);
	
	@caseSensitive
	struct Dat2
	{
		@help("help string")
		@(.opt("a"))
		bool opt;
	}
	Dat2 dat2;
	args = ["program", "-a"];
	args.parseOptions(dat2);
	assert(dat2.opt);
	
	struct Dat3
	{
		@help("forgot to put a string")
		@(.opt("a"))
		bool opt;
	}
	Dat3 dat3;
	args = ["program", ""];
	assertThrown(
		args.parseOptions(dat3));
}

/// This behavior is different from Phobos' std.getopt.
@safe unittest
{
	import std.algorithm.searching : startsWith;
	@arraySeparator(',')
	struct Dat
	{
		@opt("m")
		string[string] mapping;
	}
	Dat dat;
	string[] args = ["testProgram", "-m", "a=b,c=\"d,e,f\""];
	// getopt may thrown but parseOptions is not
	args.parseOptions(dat);
	assert("a" in dat.mapping);
	assert("c" in dat.mapping);
	assert("e" in dat.mapping);
	assert("f\"" in dat.mapping);
	assert(dat.mapping["a"] == "b");
	assert(dat.mapping["c"] == "\"d");
	assert(dat.mapping["e"] == null);
	assert(dat.mapping["f\""] == null);
}

///
@safe unittest
{
	import std.conv;
	
	@arraySeparator(',')
	struct Dat
	{
		@opt("n|name")
		string[] names;
	}
	Dat dat;
	auto args = ["program.name", "-nfoo,bar,baz"];
	args.parseOptions(dat);
	assert(dat.names == ["foo", "bar", "baz"], to!string(dat.names));

	dat = Dat.init;
	args = ["program.name", "-n", "foo,bar,baz"];
	args.parseOptions(dat);
	assert(dat.names == ["foo", "bar", "baz"], to!string(dat.names));

	dat = Dat.init;
	args = ["program.name", "--name=foo,bar,baz"];
	args.parseOptions(dat);
	assert(dat.names == ["foo", "bar", "baz"], to!string(dat.names));

	dat = Dat.init;
	args = ["program.name", "--name", "foo,bar,baz"];
	args.parseOptions(dat);
	assert(dat.names == ["foo", "bar", "baz"], to!string(dat.names));
}

///
@safe unittest
{
	import std.conv;
	
	struct Dat
	{
		@opt("values|v")
		int[string] values;
	}
	Dat dat;
	
	dat.values = dat.values.init;
	auto args = ["program.name", "-vfoo=0,bar=1,baz=2"];
	args.parseOptions(dat);
	assert(dat.values == ["foo":0, "bar":1, "baz":2], to!string(dat.values));
	
	dat.values = dat.values.init;
	args = ["program.name", "-v", "foo=0,bar=1,baz=2"];
	args.parseOptions(dat);
	assert(dat.values == ["foo":0, "bar":1, "baz":2], to!string(dat.values));
	
	dat.values = dat.values.init;
	args = ["program.name", "--values=foo=0,bar=1,baz=2"];
	args.parseOptions(dat);
	assert(dat.values == ["foo":0, "bar":1, "baz":2], to!string(dat.values));
	
	dat.values = dat.values.init;
	args = ["program.name", "--values", "foo=0,bar=1,baz=2"];
	args.parseOptions(dat);
	assert(dat.values == ["foo":0, "bar":1, "baz":2], to!string(dat.values));
}


///
@safe unittest
{
	import std.conv, std.math;
	
	static struct Dat
	{
		@opt("foo")
		@convBy!(a => a ~ a)
		string valueStr;
		
		@ignore
		static void convBar(ref int dst, string src)
		{
			import std.conv;
			dst = to!int(src);
		}
		
		@ignore
		static void convHoge(ref Dat dst, string src)
		{
			import std.conv, std.range, std.array;
			auto v = to!int(src);
			dst.hogeLen = v;
			dst.hoge = repeat("hoge", v).join;
		}
		
		@opt("bar")
		@convBy!convBar
		int valueI32;
		
		float valueF32;
		
		@ignore
		size_t hogeLen;
		@convBy!convHoge
		string hoge;
	}
	Dat dat;
	
	dat.valueStr = dat.valueStr.init;
	dat.valueI32 = dat.valueI32.init;
	dat.valueF32 = dat.valueF32.init;
	auto args = ["program.name", "--foo=aaa", "--bar=12345", "--valueF32=10", "--hoge=3"];
	args.parseOptions(dat);
	assert(dat.valueStr == "aaaaaa");
	assert(dat.valueI32 == 12345);
	assert(dat.valueF32.approxEqual(10.0f));
	assert(dat.hogeLen == 3);
	assert(dat.hoge == "hogehogehoge");
}
