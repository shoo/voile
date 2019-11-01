module voile.json;

import voile.misc;
import std.json, std.traits, std.conv, std.array;


/*******************************************************************************
 * JSONValueデータを得る
 */
JSONValue json(T)(auto const ref T[] x) @property
	if (isSomeString!(T[]))
{
	return JSONValue(to!string(x));
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
JSONValue json(T)(auto const ref T x) @property
	if (is(T == enum))
{
	return JSONValue(x.to!string());
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
	assert(dstrjson.type == JSONType.string);
	assert(wstrjson.type == JSONType.string);
	assert(strjson.type  == JSONType.string);
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
			assert(xjson.type == JSONType.uinteger);
			assert(xjson.uinteger == 123);
		}
		else
		{
			assert(xjson.type == JSONType.integer);
			assert(xjson.integer == 123);
		}
	}
	foreach (T; TypeTuple!(float, double, real))
	{
		T x = 0.125;
		auto xjson = x.json;
		assert(xjson.type == JSONType.float_);
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
	assert(btjson.type == JSONType.true_);
	assert(bfjson.type == JSONType.false_);
}

///
@system unittest
{
	enum EnumType
	{
		a, b, c
	}
	auto a = EnumType.a;
	auto ajson = a.json;
	assert(ajson.type == JSONType.string);
	assert(ajson.str == "a");
}


///
@system unittest
{
	auto ary = [1,2,3];
	auto aryjson = ary.json;
	assert(aryjson.type == JSONType.array);
	assert(aryjson[0].type == JSONType.integer);
	assert(aryjson[1].type == JSONType.integer);
	assert(aryjson[2].type == JSONType.integer);
	assert(aryjson[0].integer == 1);
	assert(aryjson[1].integer == 2);
	assert(aryjson[2].integer == 3);
}

///
@system unittest
{
	auto ary = ["ab","cd","ef"];
	auto aryjson = ary.json;
	assert(aryjson.type == JSONType.array);
	assert(aryjson[0].type == JSONType.string);
	assert(aryjson[1].type == JSONType.string);
	assert(aryjson[2].type == JSONType.string);
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
	assert(aryjson.type == JSONType.array);
	assert(aryjson[0].type == JSONType.object);
	assert(aryjson[1].type == JSONType.object);
	assert(aryjson[2].type == JSONType.object);
	assert(aryjson[0]["a"].type == JSONType.integer);
	assert(aryjson[1]["a"].type == JSONType.integer);
	assert(aryjson[2]["a"].type == JSONType.integer);
	assert(aryjson[0]["a"].integer == 1);
	assert(aryjson[1]["a"].integer == 2);
	assert(aryjson[2]["a"].integer == 3);
}


private void _setValue(T)(ref JSONValue v, ref string name, ref T val)
	if (is(typeof(val.json)))
{
	if (v.type != JSONType.object || !v.object)
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
	assert(json.type == JSONType.object);
	assert("dat" in json.object);
	assert(json["dat"].type == JSONType.integer);
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
	assert(json.type == JSONType.object);
	assert("type" in json.object);
	assert(json["type"].type == JSONType.string);
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
	if (src.type == JSONType.string)
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
	if (src.type == JSONType.integer)
	{
		dst = cast(T)src.integer;
		return true;
	}
	else if (src.type == JSONType.uinteger)
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
	case JSONType.float_:
		dst = cast(T)src.floating;
		return true;
	case JSONType.integer:
		dst = cast(T)src.integer;
		return true;
	case JSONType.uinteger:
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
	if (src.type == JSONType.object)
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
		if (x.type == JSONType.object)
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
	if (src.type == JSONType.object)
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
		if (x.type == JSONType.object)
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
	if (src.type == JSONType.string)
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
	if (src.type == JSONType.true_)
	{
		dst = true;
		return true;
	}
	else if (src.type == JSONType.false_)
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
	if (src.type == JSONType.array)
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
	if (src.type == JSONType.object)
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
			assert(v.type == JSONType.object);
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


import std.typecons: Rebindable;

///
alias JSONValueArray  = Rebindable!(const(JSONValue[]));
///
alias JSONValueObject = Rebindable!(const(JSONValue[string]));

/*******************************************************************************
 * 
 */
bool getArray(JSONValue json, string name, ref JSONValueArray ary)
{
	if (json.type != JSONType.object)
		return false;
	if (auto p = name in json)
	{
		if (p.type != JSONType.array)
			return false;
		ary = p.array;
		return true;
	}
	return false;
}

/*******************************************************************************
 * 
 */
bool getObject(JSONValue json, string name, ref JSONValueObject object)
{
	if (json.type != JSONType.object)
		return false;
	if (auto p = name in json)
	{
		if (p.type != JSONType.object)
			return false;
		object = p.object;
		return true;
	}
	return false;
}

///
struct AttrName
{
	///
	string name;
}
///
struct AttrEssential
{
}
///
struct AttrIgnore
{
}
///
struct AttrConverter(T)
{
	///
	T function(in JSONValue v) from;
	///
	JSONValue function(in T v) to;
}


/*******************************************************************************
 * Attribute forcing field name
 */
AttrName name(string name)
{
	return AttrName(name);
}

/*******************************************************************************
 * Attribute converting method
 */
AttrConverter!T converter(T)(T function(in JSONValue) from, JSONValue function(in T) to)
{
	return AttrConverter!T(from, to);
}

/*******************************************************************************
 * Attribute marking essential field
 */
enum AttrEssential essential = AttrEssential.init;

/*******************************************************************************
 * Attribute marking ignore data
 */
enum AttrIgnore ignore = AttrIgnore.init;


private enum isJSONizableRaw(T) = is(typeof({
	T val;
	JSONValue jv= val.json;
	fromJson(jv, val);
}));

/*******************************************************************************
 * serialize data to JSON
 */
JSONValue serializeToJson(T)(in T data)
{
	static if (isJSONizableRaw!T)
	{
		return data.json;
	}
	else static if (isArray!T)
	{
		JSONValue[] jvAry;
		auto len = data.length;
		jvAry.length = len;
		foreach (idx; 0..len)
			jvAry[idx] = serializeToJson(data[idx]);
		return JSONValue(jvAry);
	}
	else static if (isAssociativeArray!T)
	{
		JSONValue[string] jvObj;
		foreach (pair; data.byPair)
			jvObj[pair.key.to!string()] = serializeToJson(pair.value);
		return JSONValue(jvObj);
	}
	else
	{
		JSONValue ret;
		static foreach (memberIdx, member; T.tupleof)
		{{
			static if (!hasUDA!(member, AttrIgnore))
			{
				static if (hasUDA!(member, AttrName))
				{
					enum fieldName = getUDAs!(member, AttrName)[$-1].name;
				}
				else
				{
					enum fieldName = __traits(identifier, member);
				}
				static if (hasUDA!(member, AttrConverter!(typeof(member))))
				{
					ret[fieldName] = getUDAs!(member, AttrConverter!(typeof(member)))[$-1].to(data.tupleof[memberIdx]);
				}
				else static if (isJSONizableRaw!(typeof(member)))
				{
					ret[fieldName] = data.tupleof[memberIdx].json;
				}
				else
				{
					ret[fieldName] = serializeToJson(data.tupleof[memberIdx]);
				}
			}
		}}
		return ret;
	}
}

/// ditto
string serializeToJsonString(T)(in T data)
{
	return serializeToJson(data).toPrettyString();
}

/// ditto
void serializeToJsonFile(T)(in T data, string jsonfile)
{
	import std.file, std.encoding;
	auto contents = serializeToJsonString(data);
	std.file.write(jsonfile, contents);
}

/*******************************************************************************
 * deserialize data from JSON
 */
void deserializeFromJson(T)(ref T data, in JSONValue json)
{
	static if (isJSONizableRaw!T)
	{
		fromJson(json, data);
	}
	else static if (isArray!T)
	{
		if (json.type != JSONType.array)
			return;
		auto jvAry = json.array;
		static if (isDynamicArray!T)
			data.length = jvAry.length;
		foreach (idx, ref dataElm; data)
			deserializeFromJson(dataElm, jvAry[idx]);
	}
	else static if (isAssociativeArray!T)
	{
		if (json.type != JSONType.object)
			return;
		data.clear();
		alias KeyType = typeof(data.byKey.front);
		alias ValueType = typeof(data.byValue.front);
		foreach (pair; json.object.byPair)
		{
			import std.algorithm: move;
			data.update(pair.key.to!KeyType(),
			{
				ValueType ret;
				deserializeFromJson(ret, pair.value);
				return ret.move();
			}, (ref ValueType ret)
			{
				deserializeFromJson(ret, pair.value);
				return ret;
			});
		}
	}
	else
	{
		static foreach (memberIdx, member; T.tupleof)
		{{
			static if (!hasUDA!(member, AttrIgnore))
			{
				static if (hasUDA!(member, AttrName))
				{
					enum fieldName = getUDAs!(member, AttrName)[$-1].name;
				}
				else
				{
					enum fieldName = __traits(identifier, member);
				}
				static if (hasUDA!(member, AttrConverter!(typeof(member))))
				{
					static if (hasUDA!(member, AttrEssential))
					{
						data.tupleof[memberIdx] = getUDAs!(member, AttrConverter!(typeof(member)))[$-1].from(json[fieldName]);
					}
					else
					{
						if (auto pJsonValue = fieldName in json)
						{
							try
								data.tupleof[memberIdx] = getUDAs!(member, AttrConverter!(typeof(member)))[$-1].from(*pJsonValue);
							catch (Exception e)
							{
								/* ignore */
							}
						}
						
					}
				}
				else static if (isJSONizableRaw!(typeof(member)))
				{
					static if (hasUDA!(member, AttrEssential))
					{
						fromJson(json[fieldName], data.tupleof[memberIdx]);
					}
					else
					{
						import std.algorithm: move;
						auto tmp = json.getValue(fieldName, data.tupleof[memberIdx]);
						move(tmp, data.tupleof[memberIdx]);
					}
				}
				else
				{
					static if (hasUDA!(member, AttrEssential))
					{
						deserializeFromJson(data.tupleof[memberIdx], json[fieldName]);
					}
					else
					{
						if (auto pJsonValue = fieldName in json)
							deserializeFromJson(data.tupleof[memberIdx], *pJsonValue);
					}
				}
			}
		}}
	}
}

/// ditto
void deserializeFromJsonString(T)(ref T data, string jsonContents)
{
	deserializeFromJson(data, parseJSON(jsonContents));
}

/// ditto
void deserializeFromJsonFile(T)(ref T data, string jsonFile)
{
	import std.file;
	deserializeFromJsonString(data, std.file.readText(jsonFile));
}

///
@system unittest
{
	import std.exception, std.datetime.systime;
	static struct Point
	{
		@name("xValue")
		int x;
		@name("yValue")
		int y = 10;
	}
	static struct Data
	{
		string key;
		int    value;
		@ignore    int    testval;
		@essential Point  pt;
		Point[] points;
		Point[string] pointMap;
		
		@converter!SysTime(jv=>SysTime.fromISOExtString(jv.str),
		                   v =>JSONValue(v.toISOExtString()))
		SysTime time;
	}
	Data x, y, z;
	x.key = "xxx";
	x.value = 200;
	x.pt.x = 300;
	x.pt.y = 400;
	x.testval = 100;
	y.testval = 200;
	auto tim = Clock.currTime();
	x.time = tim;
	JSONValue jv1     = serializeToJson(x);
	string    jsonStr = jv1.toPrettyString();
	JSONValue jv2     = parseJSON(jsonStr);
	y.deserializeFromJson(jv2);
	assert(x != y);
	y.testval = x.testval;
	assert(x == y);
	assert(jv1["pt"]["xValue"].integer == 300);
	assert(jv1["pt"]["yValue"].integer == 400);
	assert(jv1["time"].str == tim.toISOExtString());
	
	auto e1 = z.deserializeFromJson(parseJSON(`{}`)).collectException;
	import std.stdio;
	assert(e1);
	assert(e1.msg == "Key not found: pt");
	
	auto e2 = z.deserializeFromJson(parseJSON(`{"pt": {}}`)).collectException;
	assert(!e2);
	assert(z.pt.y == 10);
	assert(z.time == SysTime.init);
	
	scope (exit)
	{
		import std.file;
		if ("test.json".exists)
			"test.json".remove();
	}
	
	x.serializeToJsonFile("test.json");
	z.deserializeFromJsonFile("test.json");
	assert(x != z);
	z.testval = x.testval;
	assert(x == z);
	
	Data[] datAry1, datAry2;
	Data[string] datMap1, datMap2;
	datAry1 = [Data("x", 10, 0, Point(1,2), [Point(3,4)], ["PT": Point(5,6)])];
	datMap1 = ["Data": Data("x", 10, 0, Point(1,2), [Point(3,4)], ["PT": Point(5,6)])];
	datAry1.serializeToJsonFile("test.json");
	datAry2.deserializeFromJsonFile("test.json");
	datMap1.serializeToJsonFile("test.json");
	datMap2.deserializeFromJsonFile("test.json");
	assert(datAry1[0].points[0] == Point(3,4));
	assert(datAry1[0].pointMap["PT"] == Point(5,6));
	assert(datMap1["Data"].points[0] == Point(3,4));
	assert(datMap1["Data"].pointMap["PT"] == Point(5,6));
	assert(datAry2[0].points[0] == Point(3,4));
	assert(datAry2[0].pointMap["PT"] == Point(5,6));
	assert(datMap2["Data"].points[0] == Point(3,4));
	assert(datMap2["Data"].pointMap["PT"] == Point(5,6));
}


@system unittest
{
	enum EnumVal
	{
		val1,
		val2
	}
	struct Data
	{
		EnumVal val;
	}
	Data data1 = Data(EnumVal.val1), data2 = Data(EnumVal.val2);
	auto jv = data1.serializeToJson();
	data2.deserializeFromJson(jv);
	assert(data1.val == data2.val);
}


@system unittest
{
	struct Data
	{
		string[uint] map;
	}
	Data data1 = Data([1: "1"]);
	Data data2 = Data([2: "2"]);
	auto jv = data1.serializeToJson();
	data2.deserializeFromJson(jv);
	assert(1 in data1.map);
	assert(1 in data2.map);
	assert(2 !in data2.map);
	assert(data2.map[1] == "1");
}



///
JSONValue deepCopy(in JSONValue v) @property
{
	final switch (v.type)
	{
	case JSONType.null_:
	case JSONType.string:
	case JSONType.integer:
	case JSONType.uinteger:
	case JSONType.float_:
	case JSONType.true_:
	case JSONType.false_:
		return v;
	case JSONType.object:
		JSONValue[string] ret;
		foreach (key, val; v.object)
			ret[key] = deepCopy(val);
		return JSONValue(ret);
	case JSONType.array:
		auto ret = appender!(JSONValue[]);
		foreach (e; v.array)
			ret ~= deepCopy(e);
		return JSONValue(ret.data);
	}
}

@system unittest
{
	auto jv1 = JSONValue(["a": "A"]);
	auto jv2 = jv1;
	auto jv3 = jv1.deepCopy();
	jv1["a"] = "XXX";
	assert(jv1["a"].str == "XXX");
	assert(jv2["a"].str == "XXX");
	assert(jv3["a"].str == "A");
}
@system unittest
{
	auto jv1 = JSONValue(["a": ["A", "B", "C"]]);
	auto jv2 = jv1;
	auto jv3 = jv1.deepCopy();
	jv1["a"][0] = "XXX";
	assert(jv1["a"][0].str == "XXX");
	assert(jv2["a"][0].str == "XXX");
	assert(jv3["a"][0].str == "A");
}
