module voile.json;

import voile.misc;
import std.json, std.traits, std.conv, std.array;


/*******************************************************************************
 * JSONValueデータを得る
 */
JSONValue json(T)(auto const ref T[] x) @property
	if (isSomeString!(T[]))
{
	JSONValue v;
	v.str = to!string(x);
	return v;
}


/// ditto
JSONValue json(T)(auto const ref T x) @property
	if ((isIntegral!T && !is(T == enum))
	 || isFloatingPoint!T
	 || is(Unqual!T == bool))
{
	return JSONValue(x);
}


/// ditto
JSONValue json(T)(auto const ref T[] ary) @property
	if (!isSomeString!(T[]) && isArray!(T[]))
{
	auto app = appender!(JSONValue[])();
	JSONValue v;
	foreach (x; ary)
	{
		app.put(x.json);
	}
	v.array = app.data;
	return v;
}


/// ditto
JSONValue json(Value, Key)(auto const ref Value[Key] aa) @property
	if (isSomeString!Key && is(typeof({auto v = Value.init.json;})))
{
	auto ret = JSONValue((JSONValue[string]).init);
	static if (is(Key: const string))
	{
		foreach (key, val; aa)
			ret.object[key] = val.json;
	}
	else
	{
		foreach (key, val; aa)
			v.object[key.to!string] = val.json;
	}
	return ret;
}

/// ditto
auto ref JSONValue json(JV)(auto const ref JV v) @property
	if (is(JV: const JSONValue))
{
	return cast(JSONValue)v;
}

///
@system unittest
{
	dstring dstr = "あいうえお";
	wstring wstr = "かきくけこ";
	string  str  = "さしすせそ";
	auto dstrjson = dstr.json;
	auto wstrjson = wstr.json;
	auto strjson  = str.json;
	assert(dstrjson.type == JSON_TYPE.STRING);
	assert(wstrjson.type == JSON_TYPE.STRING);
	assert(strjson.type  == JSON_TYPE.STRING);
	assert(dstrjson.str == "あいうえお");
	assert(wstrjson.str == "かきくけこ");
	assert(strjson.str  == "さしすせそ");
}


///
@system unittest
{
	import std.typetuple;
	foreach (T; TypeTuple!(ubyte, byte, ushort, short, uint, int, ulong, long))
	{
		T x = 123;
		auto xjson = x.json;
		static if (isUnsigned!T)
		{
			assert(xjson.type == JSON_TYPE.UINTEGER);
			assert(xjson.uinteger == 123);
		}
		else
		{
			assert(xjson.type == JSON_TYPE.INTEGER);
			assert(xjson.integer == 123);
		}
	}
	foreach (T; TypeTuple!(float, double, real))
	{
		T x = 0.125;
		auto xjson = x.json;
		assert(xjson.type == JSON_TYPE.FLOAT);
		assert(xjson.floating == 0.125);
	}
}


///
@system unittest
{
	bool bt = true;
	bool bf;
	auto btjson = bt.json;
	auto bfjson = bf.json;
	assert(btjson.type == JSON_TYPE.TRUE);
	assert(bfjson.type == JSON_TYPE.FALSE);
}


///
@system unittest
{
	auto ary = [1,2,3];
	auto aryjson = ary.json;
	assert(aryjson.type == JSON_TYPE.ARRAY);
	assert(aryjson[0].type == JSON_TYPE.INTEGER);
	assert(aryjson[1].type == JSON_TYPE.INTEGER);
	assert(aryjson[2].type == JSON_TYPE.INTEGER);
	assert(aryjson[0].integer == 1);
	assert(aryjson[1].integer == 2);
	assert(aryjson[2].integer == 3);
}

///
@system unittest
{
	auto ary = ["ab","cd","ef"];
	auto aryjson = ary.json;
	assert(aryjson.type == JSON_TYPE.ARRAY);
	assert(aryjson[0].type == JSON_TYPE.STRING);
	assert(aryjson[1].type == JSON_TYPE.STRING);
	assert(aryjson[2].type == JSON_TYPE.STRING);
	assert(aryjson[0].str == "ab");
	assert(aryjson[1].str == "cd");
	assert(aryjson[2].str == "ef");
}

///
@system unittest
{
	struct A
	{
		int a = 123;
		JSONValue json() const @property
		{
			return JSONValue(["a": JSONValue(a)]);
		}
		void json(JSONValue v) @property
		{
			a = v.getValue("a", 123);
		}
	}
	auto ary = [A(1),A(2),A(3)];
	auto aryjson = ary.json;
	assert(aryjson.type == JSON_TYPE.ARRAY);
	assert(aryjson[0].type == JSON_TYPE.OBJECT);
	assert(aryjson[1].type == JSON_TYPE.OBJECT);
	assert(aryjson[2].type == JSON_TYPE.OBJECT);
	assert(aryjson[0]["a"].type == JSON_TYPE.INTEGER);
	assert(aryjson[1]["a"].type == JSON_TYPE.INTEGER);
	assert(aryjson[2]["a"].type == JSON_TYPE.INTEGER);
	assert(aryjson[0]["a"].integer == 1);
	assert(aryjson[1]["a"].integer == 2);
	assert(aryjson[2]["a"].integer == 3);
}


private void _setValue(T)(ref JSONValue v, ref string name, ref T val)
	if (is(typeof(val.json)))
{
	if (v.type != JSON_TYPE.OBJECT || !v.object)
	{
		v = [name: val.json];
	}
	else
	{
		auto x = v.object;
		x[name] = val.json;
		v = x;
	}
}

private void _setValue(T)(ref JSONValue v, ref string name, ref T val)
	if (is(T == enum))
{
	import std.string;
	if (v.type != JSON_TYPE.OBJECT || !v.object)
	{
		v = [name: format("%s", val)];
	}
	else
	{
		auto x = v.object;
		x[name] = format("%s", val);
		v = x;
	}
}

/*******************************************************************************
 * JSONValueデータの操作
 */
void setValue(T)(ref JSONValue v, string name, T val) pure nothrow @trusted
{
	try
	{
		assumePure!(_setValue!T)(v, name, val);
	}
	catch (Throwable)
	{
	}
}

///
@system unittest
{
	JSONValue json;
	json.setValue("dat", 123);
	assert(json.type == JSON_TYPE.OBJECT);
	assert("dat" in json.object);
	assert(json["dat"].type == JSON_TYPE.INTEGER);
	assert(json["dat"].integer == 123);
}



///
@system unittest
{
	enum Type
	{
		foo, bar,
	}
	JSONValue json;
	json.setValue("type", Type.foo);
	assert(json.type == JSON_TYPE.OBJECT);
	assert("type" in json.object);
	assert(json["type"].type == JSON_TYPE.STRING);
	assert(json["type"].str == "foo");
}

///
@system unittest
{
	struct A
	{
		int a = 123;
		JSONValue json() const @property
		{
			JSONValue v;
			v.setValue("a", a);
			return v;
		}
	}
	A a;
	a.a = 321;
	JSONValue json;
	json.setValue("a", a);
}


///
@system unittest
{
	JSONValue json;
	json.setValue("test", "あいうえお");
	static assert(is(typeof(json.getValue("test", "かきくけこ"d)) == dstring));
	static assert(is(typeof(json.getValue("test", "かきくけこ"w)) == wstring));
	static assert(is(typeof(json.getValue("test", "かきくけこ"c)) == string));
	assert(json.getValue("test", "かきくけこ"d) == "あいうえお"d);
	assert(json.getValue("test", "かきくけこ"w) == "あいうえお"w);
	assert(json.getValue("test", "かきくけこ"c) == "あいうえお"c);
	assert(json.getValue("hoge", "かきくけこ"c) == "かきくけこ"c);
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (isSomeString!T)
{
	if (src.type == JSON_TYPE.STRING)
	{
		static if (is(T: string))
		{
			dst = src.str;
		}
		else
		{
			dst = to!T(src.str);
		}
		return true;
	}
	return false;
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal = T.init)
	if (isSomeString!(T))
{
	T tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (isIntegral!T && !is(T == enum))
{
	if (src.type == JSON_TYPE.INTEGER)
	{
		dst = cast(T)src.integer;
		return true;
	}
	else if (src.type == JSON_TYPE.UINTEGER)
	{
		dst = cast(T)src.uinteger;
		return true;
	}
	return false;
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal)
	if (isIntegral!T && !is(T == enum))
{
	T tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (isFloatingPoint!T)
{
	switch (src.type)
	{
	case JSON_TYPE.FLOAT:
		dst = cast(T)src.floating;
		return true;
	case JSON_TYPE.INTEGER:
		dst = cast(T)src.integer;
		return true;
	case JSON_TYPE.UINTEGER:
		dst = cast(T)src.uinteger;
		return true;
	default:
		return false;
	}
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal)
	if (isFloatingPoint!T)
{
	T tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (is(T == struct) && !is(Unqual!T: JSONValue))
{
	if (src.type == JSON_TYPE.OBJECT)
	{
		dst.json = src;
		return true;
	}
	return false;
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal = T.init)
	if (is(T == struct) && !is(Unqual!T: JSONValue))
{
	if (auto x = name in v.object)
	{
		if (x.type == JSON_TYPE.OBJECT)
		{
			auto ret = T.init;
			ret.json = *x;
			return ret;
		}
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (is(T == class))
{
	if (src.type == JSON_TYPE.OBJECT)
	{
		if (!dst)
			dst = new T;
		dst.json = src;
		return true;
	}
	return false;
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal)
	if (is(T == class))
{
	if (auto x = name in v.object)
	{
		if (x.type == JSON_TYPE.OBJECT)
		{
			auto ret = new T;
			ret.json = *x;
			return ret;
		}
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (is(T == enum))
{
	if (src.type == JSON_TYPE.STRING)
	{
		dst = to!T(src.str);
		return true;
	}
	return false;
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal)
	if (is(T == enum))
{
	T tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (is(T == bool))
{
	if (src.type == JSON_TYPE.TRUE)
	{
		dst = true;
		return true;
	}
	else if (src.type == JSON_TYPE.FALSE)
	{
		dst = false;
		return true;
	}
	return false;
}


private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal)
	if (is(T == bool))
{
	T tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}


///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (!isSomeString!(T) && isDynamicArray!(T))
{
	alias E = ForeachType!T;
	if (src.type == JSON_TYPE.ARRAY)
	{
		dst = (dst.length >= src.array.length) ? dst[0..src.array.length]: new E[src.array.length];
		foreach (ref i, ref e; src.array)
		{
			if (!fromJson(e, dst[i]))
				return false;
		}
		return true;
	}
	return false;
}

private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal = T.init)
	if (!isSomeString!(T) && isDynamicArray!(T))
{
	Unqual!(ForeachType!T)[] tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? cast(T)tmp : defaultVal;
	}
	return defaultVal;
}


///
bool fromJson(Value, Key)(in ref JSONValue src, ref Value[Key] dst)
	if (isSomeString!Key && is(typeof({ JSONValue val; fromJson(val, dst[Key.init]); })))
{
	if (src.type == JSON_TYPE.OBJECT)
	{
		foreach (key, ref val; src.object)
		{
			static if (is(Key: const string))
			{
				Value tmp;
				if (!fromJson(val, tmp))
					return false;
				dst[key] = tmp;
			}
			else
			{
				Value tmp;
				if (!fromJson(val, tmp))
					return false;
				dst[to!Key(key)] = tmp;
			}
		}
		return true;
	}
	return false;
}

private T _getValue(T: Value[Key], Value, Key)(
	in ref JSONValue v, string name, lazy scope Value[Key] defaultVal = T.init)
	if (isSomeString!Key && is(typeof({ JSONValue val; Value[Key] dst; fromJson(val, dst[Key.init]); })))
{
	Value[Key] tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}

///
bool fromJson(T)(in ref JSONValue src, ref T dst)
	if (is(Unqual!T == JSONValue))
{
	dst = src;
	return true;
}

private T _getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal = T.init)
	if (is(Unqual!T == JSONValue))
{
	JSONValue tmp;
	if (auto x = name in v.object)
	{
		return fromJson(*x, tmp) ? tmp : defaultVal;
	}
	return defaultVal;
}

///
T getValue(T)(in ref JSONValue v, string name, lazy scope T defaultVal = T.init) nothrow pure @trusted
{
	try
	{
		return assumePure(&_getValue!(Unqual!T))(v, name, defaultVal);
	}
	catch(Throwable)
	{
	}
	try
	{
		return defaultVal;
	}
	catch (Throwable)
	{
	}
	return T.init;
}


///
@system unittest
{
	JSONValue json;
	json.setValue("test", 123);
	static assert(is(typeof(json.getValue("test", 654UL)) == ulong));
	static assert(is(typeof(json.getValue("test", 654U)) == uint));
	static assert(is(typeof(json.getValue("test", cast(byte)12)) == byte));
	assert(json.getValue("test", 654UL) == 123);
	assert(json.getValue("test", 654U) == 123);
	assert(json.getValue("test", cast(byte)12) == 123);
	assert(json.getValue("hoge", cast(byte)12) == 12);
}


///
@system unittest
{
	JSONValue json;
	json.setValue("test", 0.125);
	static assert(is(typeof(json.getValue("test", 0.25f)) == float));
	static assert(is(typeof(json.getValue("test", 0.25)) == double));
	static assert(is(typeof(json.getValue("test", 0.25L)) == real));
	assert(json.getValue("test", 0.25f) == 0.125f);
	assert(json.getValue("test", 0.25) == 0.125);
	assert(json.getValue("test", 0.25L) == 0.125L);
	assert(json.getValue("hoge", 0.25L) == 0.25L);
}


///
@system unittest
{
	struct A
	{
		int a = 123;
		JSONValue json() const @property
		{
			JSONValue v;
			v.setValue("a", a);
			return v;
		}
		void json(JSONValue v) @property
		{
			a = v.getValue("a", 123);
		}
	}
	A a;
	a.a = 321;
	JSONValue json;
	json.setValue("a", a);
	static assert(is(typeof(json.getValue("a", A(456))) == A));
	assert(json.getValue("a", A(456)).a == 321);
	assert(json.getValue("b", A(456)).a == 456);
}


///
@system unittest
{
	static class A
	{
		int a = 123;
		JSONValue json() const @property
		{
			JSONValue v;
			v.setValue("a", a);
			return v;
		}
		void json(JSONValue v) @property
		{
			a = v.getValue("a", 123);
		}
	}
	auto a = new A;
	a.a = 321;
	JSONValue json;
	json.setValue("a", a);
	static assert(is(typeof(json.getValue!A("a")) == A));
	assert(json.getValue!A("a").a == 321);
	assert(json.getValue!A("b") is null);
}


///
@system unittest
{
	enum Type
	{
		foo, bar
	}
	JSONValue json;
	json.setValue("a", Type.bar);
	static assert(is(typeof(json.getValue("a", Type.foo)) == Type));
	assert(json.getValue("a", Type.foo) == Type.bar);
	assert(json.getValue("b", Type.foo) == Type.foo);
}


///
@system unittest
{
	JSONValue json;
	json.setValue("t", true);
	json.setValue("f", false);
	static assert(is(typeof(json.getValue("t", true)) == bool));
	static assert(is(typeof(json.getValue("f", false)) == bool));
	assert(json.getValue("t", true) == true);
	assert(json.getValue("f", true) == false);
	assert(json.getValue("t", false) == true);
	assert(json.getValue("f", false) == false);
	assert(json.getValue("x", true) == true);
	assert(json.getValue("x", false) == false);
}


///
@system unittest
{
	JSONValue json;
	json.setValue("test1", [1,2,3]);
	auto x = json.getValue("test1", [2,3,4]);
	
	static assert(is(typeof(json.getValue("test1", [2,3,4])) == int[]));
	assert(json.getValue("test1", [2,3,4]) == [1,2,3]);
	assert(json.getValue("test1x", [2,3,4]) == [2,3,4]);
	
	json.setValue("test2", [0.5,0.25,0.125]);
	static assert(is(typeof(json.getValue("test2", [0.5,0.5,0.5])) == double[]));
	assert(json.getValue("test2", [0.5,0.5,0.5]) == [0.5,0.25,0.125]);
	assert(json.getValue("test2x", [0.5,0.5,0.5]) == [0.5,0.5,0.5]);
	
	json.setValue("test3", ["ab","cd","ef"]);
	static assert(is(typeof(json.getValue("test3", ["あい","うえ","おか"])) == string[]));
	assert(json.getValue("test3", ["あい","うえ","おか"]) == ["ab","cd","ef"]);
	assert(json.getValue("test3x", ["あい","うえ","おか"]) == ["あい","うえ","おか"]);
	
	json.setValue("test4", [true, false, true]);
	static assert(is(typeof(json.getValue("test4", [false, true, true])) == bool[]));
	assert(json.getValue("test4", [false, true, true]) == [true, false, true]);
	assert(json.getValue("test4x", [false, true, true]) == [false, true, true]);
}


///
@system unittest
{
	static struct A
	{
		int a = 123;
		JSONValue json() const @property
		{
			JSONValue v;
			v.setValue("a", a);
			return v;
		}
		void json(JSONValue v) @property
		{
			assert(v.type == JSON_TYPE.OBJECT);
			a = v.getValue("a", 123);
		}
	}
	auto a = [A(1),A(2),A(3)];
	JSONValue json;
	json.setValue("a", a);
	static assert(is(typeof(json.getValue("a", [A(4),A(5),A(6)])) == A[]));
	assert(json.getValue("a", [A(4),A(5),A(6)]) == [A(1),A(2),A(3)]);
	assert(json.getValue("b", [A(4),A(5),A(6)]) == [A(4),A(5),A(6)]);
}
