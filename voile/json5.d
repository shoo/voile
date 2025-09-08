/*******************************************************************************
 * JSON5 data module
 * 
 * This module provides functionality for working with JSON5 (JavaScript Object Notation ver.5) data.
 * It includes definitions for various JSON5 data types, a builder for constructing JSON5 values,
 * and methods for converting between JSON5 and native D types.
 * 
 * See_Also: [specs.json5.org](https://spec.json5.org/)
 */
module voile.json5;

import std.sumtype, std.traits, std.exception, std.meta;
import std.format, std.conv, std.string;
import std.algorithm, std.range, std.array;
import std.typecons: Tuple, tuple, isTuple;
import std.json: StdJsonValue = JSONValue, StdJsonType = JSONType;
import voile.attr;
alias attr = voile.attr;

alias ignore      = voile.attr.ignore;
alias ignoreIf    = voile.attr.ignoreIf;
alias name        = voile.attr.name;
alias value       = voile.attr.value;
alias convertFrom = voile.attr.convertFrom;
alias convertTo   = voile.attr.convertTo;

//##############################################################################
//##### MARK: Attributes
//##############################################################################



private struct Kind
{
	string key;
	string value;
}

/*******************************************************************************
 * Kind attribute
 * 
 * Attribute used for serialization of SumType.
 * By adding this attribute to all aggregate types used in SumType, they become serializable.
 */
auto kind(string name, string value)
{
	return Kind(name, value);
}

/// ditto
auto kind(string value)
{
	return Kind("$type", value);
}

/// ditto
auto kind(string value)()
{
	return Kind("$type", value);
}

private enum hasKind(T) = hasUDA!(T, Kind);
private enum getKind(T) = getUDAs!(T, Kind)[0];


/*******************************************************************************
 * Attribute converting method
 */
auto converter(T1, T2)(void function(in T2, ref T1) @safe from, void function(in T1, ref T2) @safe to)
{
	alias FnFrom = typeof(from);
	alias FnTo   = typeof(to);
	static struct AttrConverter
	{
		FnFrom from;
		FnTo   to;
	}
	return AttrConverter(from, to);
}
/// ditto
auto converter(T1, T2)(T1 function(in T2) @safe from, T2 function(in T1) @safe to)
{
	alias FnFrom = typeof(from);
	alias FnTo   = typeof(to);
	static struct AttrConverter
	{
		FnFrom from;
		FnTo   to;
	}
	return AttrConverter(from, to);
}
/// ditto
auto converterString(T)(T function(string) @safe from, string function(in T) @safe to)
	=> converter!T(from, to);
/// ditto
alias convStr = converterString;
/// ditto
auto converterBinary(T)(T function(immutable(ubyte)[]) @safe from, immutable(ubyte)[] function(in T) @safe to)
	=> converter!T(from, to);
/// ditto
alias convBin = converterBinary;

/*******************************************************************************
 * Special conveter attributes
 */
auto converterSysTime() @safe
{
	import std.datetime;
	return convStr!SysTime(
		(src) @safe => SysTime.fromISOExtString(src),
		(src) @safe => src.toISOExtString());
}
/// ditto
auto converterDateTime() @safe
{
	import std.datetime;
	return convStr!DateTime(
		(src) @safe => DateTime.fromISOExtString(src),
		(src) @safe => src.toISOExtString());
}
/// ditto
auto converterDate() @safe
{
	import std.datetime;
	return convStr!Date(
		(src) @safe => Date.fromISOExtString(src),
		(src) @safe => src.toISOExtString());
}
/// ditto
auto converterTimeOfDay() @safe
{
	import std.datetime;
	return convStr!TimeOfDay(
		(src) @safe => TimeOfDay.fromISOExtString(src),
		(src) @safe => src.toISOExtString());
}
/// ditto
auto converterDuration()
{
	import core.time;
	return converter!(Duration, Json5Value)(
		(in Json5Value src, ref Duration dst) @safe { dst = src.get!long.hnsecs; },
		(in Duration src, ref Json5Value dst) @safe { dst = src.total!"hnsecs"(); });
}
/// ditto
auto converterUUID()
{
	import std.uuid;
	return convStr!UUID(
		src => UUID(src),
		src => src.toString());
}

///
enum CommentType
{
	line, block, trailing
}

private struct AttrJson5Comment
{
	string value;
	CommentType type;
}
private enum hasAttrJson5Comment(alias variable) = hasUDA!(variable, AttrJson5Comment);
private enum getAttrJson5Comments(alias variable) = getUDAs!(variable, AttrJson5Comment);
private enum getAttrJson5Comment(alias variable) = getAttrJson5Comment!variable[0];

/*******************************************************************************
 * Attribute of JSON5 Comment
 */
auto comment(string cmt, CommentType type = CommentType.line)
{
	return AttrJson5Comment(cmt, type);
}


private struct AttrJson5StringFormat
{
	bool singleQuoted;
}
private enum hasAttrJson5StringFormat(alias variable) = hasUDA!(variable, AttrJson5StringFormat);
private enum getAttrJson5StringFormat(alias variable) = getUDAs!(variable, AttrJson5StringFormat)[0];

/*******************************************************************************
 * Attribute of JSON5 string display format
 */
auto stringFormat(bool singleQuote = false)
{
	return AttrJson5StringFormat(singleQuote);
}
/// ditto
enum singleQuotedStr = stringFormat(true);


private struct AttrJson5IntegralFormat
{
	bool positiveSign;
	bool hex;
}
private enum hasAttrJson5IntegralFormat(alias variable) = hasUDA!(variable, AttrJson5IntegralFormat);
private enum getAttrJson5IntegralFormat(alias variable) = getUDAs!(variable, AttrJson5IntegralFormat)[0];

/*******************************************************************************
 * Attribute of JSON5 integral number display format
 */
auto integralFormat(bool positiveSign = false, bool hex = false)
{
	return AttrJson5IntegralFormat(positiveSign, hex);
}

private struct AttrJson5FloatingPointFormat
{
	bool leadingDecimalPoint;
	bool tailingDecimalPoint;
	bool positiveSign;
	bool withExponent;
	size_t precision;
}
private enum hasAttrJson5FloatingPointFormat(alias variable) = hasUDA!(variable, AttrJson5FloatingPointFormat);
private enum getAttrJson5FloatingPointFormat(alias variable) = getUDAs!(variable, AttrJson5FloatingPointFormat)[0];


/*******************************************************************************
 * Attribute of JSON5 floating point number display format
 */
auto floatingPointFormat(
	bool leadingDecimalPoint = false,
	bool tailingDecimalPoint = false,
	bool positiveSign = false,
	bool withExponent = false,
	size_t precision = 0)
{
	return AttrJson5FloatingPointFormat(
		leadingDecimalPoint, tailingDecimalPoint, positiveSign, withExponent, precision);
}

private struct AttrJson5ArrayFormat
{
	bool tailingComma;
	bool singleLine;
}
private enum hasAttrJson5ArrayFormat(alias variable) = hasUDA!(variable, AttrJson5ArrayFormat);
private enum getAttrJson5ArrayFormat(alias variable) = getUDAs!(variable, AttrJson5ArrayFormat)[0];

/*******************************************************************************
 * Attribute of JSON5 floating point number display format
 */
auto arrayFormat(bool tailingComma = false, bool singleLine = false)
{
	return AttrJson5ArrayFormat(tailingComma, singleLine);
}
/// ditto
enum singleLineAry = arrayFormat(false, true);

private alias AttrJson5ObjectFormat = AttrJson5ArrayFormat;
private enum hasAttrJson5ObjectFormat(alias variable) = hasUDA!(variable, AttrJson5ObjectFormat);
private enum getAttrJson5ObjectFormat(alias variable) = getUDAs!(variable, AttrJson5ObjectFormat)[0];

/*******************************************************************************
 * Attribute of JSON5 floating point number display format
 */
auto objectFormat(bool tailingComma = false, bool singleLine = false)
{
	return AttrJson5ObjectFormat(tailingComma, singleLine);
}
/// ditto
enum singleLineObj = objectFormat(false, true);


///
enum QuotedStyle
{
	doubleQuoted,
	unquoted,
	singleQuoted,
}

private struct AttrJson5KeyQuotedStyle
{
	QuotedStyle style;
}
private enum hasAttrJson5KeyQuotedStyle(alias variable) = hasUDA!(variable, AttrJson5KeyQuotedStyle);
private enum getAttrJson5KeyQuotedStyle(alias variable) = getUDAs!(variable, AttrJson5KeyQuotedStyle)[0];

/*******************************************************************************
 * Attribute of JSON5 integral number display format
 */
auto quotedKeyStyle(QuotedStyle style)
{
	return AttrJson5KeyQuotedStyle(style);
}
/// ditto
enum unquotedKey = quotedKeyStyle(QuotedStyle.unquoted);
/// ditto
enum singleQuotedKey = quotedKeyStyle(QuotedStyle.singleQuoted);


//##############################################################################
//##### MARK: Traits
//##############################################################################

/*******************************************************************************
 * Determines if the type is binary
 */
enum isBinary(T) = is(T == immutable(ubyte)[]);


private enum isArrayWithoutBinary(T) = isArray!T && !isBinary!T;

/*******************************************************************************
 * Determines if the Tuple can be serialized to JSON format
 * 
 * This template returns true if the type T meets the following conditions:
 * - T is a Tuple
 * - All members of the Tuple are serializable
 * 
 * Params:
 *      T = The type to check
 * Returns: true if T is a serializable tuple, false otherwise
 */
enum isSerializableTuple(T) = isTuple!T && allSatisfy!(isSerializable, T.Types);

/*******************************************************************************
 * Determines if the SumType can be serialized to JSON format
 * 
 * This template returns true if the type T meets the following conditions:
 * - T is a SumType
 * - All members of the SumType are serializable
 * - All members of the SumType have the @kind attribute if they are aggregate types
 * - There is at most one member of each of the following types:
 *   integral, floating point, boolean, string, binary, array, associative array
 * 
 * Params:
 *      T = The type to check
 * Returns: true if T is a serializable sum type, false otherwise
 */
enum isSerializableSumType(T) = isSumType!T
	&& allSatisfy!(isSerializable, T.Types)
	&& allSatisfy!(hasKind, Filter!(isAggregateType, T.Types))
	&& Filter!(isIntegral, T.Types).length <= 1
	&& Filter!(isFloatingPoint, T.Types).length <= 1
	&& Filter!(isBoolean, T.Types).length <= 1
	&& Filter!(isSomeString, T.Types).length <= 1
	&& Filter!(isBinary, T.Types).length <= 1
	&& Filter!(isAssociativeArray, T.Types).length <= 1;

/// ditto
@safe unittest
{
	@kind("test1") struct Test1 { int value; }
	@kind("test2") struct Test2 { int value; }
	alias ST1 = SumType!(Test1, Test2);
	static assert(allSatisfy!(hasKind, ST1.Types));
	static assert(allSatisfy!(isSerializable, ST1.Types));
	
	struct Test3 { int value; }
	alias ST2 = SumType!(Test1, Test2, Test3);
	static assert(!allSatisfy!(hasKind, ST2.Types));
	static assert(!isSerializableSumType!ST2);
	static assert(!isSerializableData!ST2);
	static assert(!isSerializable!ST2);
	
	alias ST3 = SumType!(int, ulong, string, immutable(ubyte)[]);
	static assert(!isSerializableSumType!ST3);
	static assert(!isSerializable!ST3);
}

private enum isJson5Value(T) = isInstanceOf!(JsonValue, T);
private alias builderOf(T) = TemplateArgsOf!(T, JsonValue)[0];

private template hasConvertJsonMethodA(T)
{
	static if (is(typeof(T.toJson)))
	{
		alias JsonValueT = ReturnType!(T.toJson);
		static if (isJson5Value!JsonValueT)
		{
			alias BuilderT = builderOf!JsonValueT;
			enum bool hasConvertJsonMethodA = is(typeof(T.toJson(lvalueOf!BuilderT)) == JsonValueT)
				&& is(typeof(T.fromJson(lvalueOf!JsonValueT)) == T);
		}
		else
		{
			enum bool hasConvertJsonMethodA = false;
		}
	}
	else
	{
		enum bool hasConvertJsonMethodA = false;
	}
}
private template hasConvertJsonMethodB(T)
{
	static if (is(typeof(T.toJson)))
	{
		alias JsonValueT = ReturnType!(T.toJson);
		static if (isJson5Value!JsonValueT)
		{
			alias BuilderT = builderOf!JsonValueT;
			enum bool hasConvertJsonMethodB = is(typeof(T.toJson()) == JsonValueT)
				&& is(typeof(T.fromJson(lvalueOf!JsonValueT)) == T);
		}
		else
		{
			enum bool hasConvertJsonMethodB = false;
		}
	}
	else
	{
		enum bool hasConvertJsonMethodB = false;
	}
}
private enum hasConvertJsonMethodC(T) = is(typeof(T.toJson()) == StdJsonValue)
	&& is(typeof(T.fromJson(lvalueOf!StdJsonValue)) == T);
private enum hasConvertJsonMethod(T) = hasConvertJsonMethodA!T || hasConvertJsonMethodB!T || hasConvertJsonMethodC!T;
private enum hasConvertJsonBinaryMethodA(T) = is(typeof(T.toBinary()) == immutable(ubyte)[])
	&& is(typeof(T.fromBinary((immutable(ubyte)[]).init)) == T);
private enum hasConvertJsonBinaryMethodB(T) = is(typeof(T.toRepresentation()) == immutable(ubyte)[])
	&& is(typeof(T.fromRepresentation((immutable(ubyte)[]).init)) == T);
private enum hasConvertJsonBinaryMethodC(T) = is(typeof(T.toRepresentation()) == string)
	&& is(typeof(T.fromRepresentation(string.init)) == T);
private enum hasConvertJsonBinaryMethod(T) = hasConvertJsonBinaryMethodA!T
	|| hasConvertJsonBinaryMethodB!T || hasConvertJsonBinaryMethodC!T;
private enum isSerializableData(T) = isIntegral!T
	|| isFloatingPoint!T
	|| isBoolean!T
	|| isSomeString!T
	|| isBinary!T
	|| isArray!T
	|| isAssociativeArray!T
	|| (isAggregateType!T
		&& !hasElaborateAssign!T
		&& !hasElaborateCopyConstructor!T
		&& !hasElaborateMove!T
		&& !hasElaborateDestructor!T
		&& !hasNested!T
		&& !isSumType!T)
	|| (isAggregateType!T && hasConvertJsonMethod!T)
	|| (isAggregateType!T && hasConvertJsonBinaryMethod!T);
private enum isAccessible(alias var) = __traits(getVisibility, var).startsWith("public", "export") != 0;

/*******************************************************************************
 * Checks if a given type is serializable to JSON format.
 *
 * This function determines whether a type can be serialized into the JSON (JavaScript Object Notation) format.
 * JSON is a binary data serialization format which aims to provide a more compact representation compared to JSON.
 *
 * Params:
 *   T = The type to check for serializability.
 *
 * Returns:
 *   bool - `true` if the type is serializable to JSON, `false` otherwise.
 */
template isSerializable(T)
{
	static if (isArray!T && !isBinary!T && !isSomeString!T)
		enum isSerializable = isSerializable!(ElementType!T);
	else static if (isAssociativeArray!T)
		enum isSerializable = isSerializable!(KeyType!T) && isSerializable!(ValueType!T);
	else static if (isSerializableSumType!T)
		enum isSerializable = true;
	else static if (isSerializableTuple!T)
		enum isSerializable = true;
	else static if (isAggregateType!T && !isSumType!T && !isInstanceOf!(Tuple, T))
		enum isSerializable = () {
			bool ret = true;
			static foreach (var; Filter!(isAccessible, T.tupleof[]))
				ret &= hasIgnore!var || hasValue!var || isSerializable!(typeof(var));
			return ret;
		}();
	else
		enum isSerializable = isSerializableData!T;
}

//##############################################################################
//##### MARK: Default Allocator
//##############################################################################

/*******************************************************************************
 * 
 */
mixin template Json5DefaultAllocator()
{
	enum String: string { init = string.init }
	struct Dictionary(K, V)
	{
	private:
		struct Item
		{
			K key;
			V value;
		}
		Item[] items;
	public:
		///
		auto byKeyValue() inout => items;
		///
		auto prepend(K k, V v) => items = Item(k, v) ~ items;
		///
		auto append(K k, V v) => items ~= Item(k, v);
		///
		bool empty() const => items.length == 0;
		///
		size_t length() const => items.length;
		///
		V* opIn(K key)
		{
			foreach (ref item; items)
			{
				if (item.key == key)
					return &item.value;
			}
			return null;
		}
		///
		ref Item opIndex(size_t idx) => items[idx];
		///
		ref V opIndex(K key)
		{
			if (auto p = this.opIn(key))
				return *p;
			throw new Exception(format("Key '%s' not found", key));
		}
	}
	template Array(T) { enum Array: T[] { init = T[].init } }
	
	auto allocStr()() => String.init;
	auto allocStr()(string s) => cast(String)s;
	auto allocDic(K, V)() => Dictionary!(K, V).init;
	auto allocAry(T)() => Array!T.init;
	
	void clearAry(Ary)(ref Ary ary) @trusted { ary = null; }
	auto copyStr()(in String str) @trusted => cast(String)str[];
}



//##############################################################################
//##### MARK: - JsonValue
//##############################################################################

/*******************************************************************************
 * 
 */
static struct JsonValue(Builder)
{
	//##########################################################################
	//##### MARK: - - JsonTypes
	//##########################################################################
	///
	alias String = Builder.String;
	///
	alias Dictionary = Builder.Dictionary;
	///
	alias Array = Builder.Array;
	///
	static struct JsonString
	{
		///
		String value;
		///
		bool singleQuoted;
		
		///
		alias value this;
	}
	///
	static struct JsonInteger
	{
		///
		long value;
		///
		bool positiveSign;
		///
		bool hex;
		
		///
		alias value this;
	}
	///
	static struct JsonUInteger
	{
		///
		ulong value;
		///
		bool positiveSign;
		///
		bool hex;
		
		///
		alias value this;
	}
	///
	static struct JsonFloatingPoint
	{
		///
		double value;
		///
		bool leadingDecimalPoint;
		///
		bool tailingDecimalPoint;
		///
		bool positiveSign;
		///
		bool withExponent;
		///
		size_t precision;
		///
		alias value this;
	}
	///
	static struct JsonKey
	{
		///
		String value;
		/// ditto
		QuotedStyle quotedStyle;
		///
		bool opEquals(in JsonKey lhs) const
		{
			return value[] == lhs.value[];
		}
		///
		size_t toHash() const
		{
			return value[].hashOf();
		}
	}
	///
	static struct JsonObject
	{
		///
		Dictionary!(JsonKey, JsonValue) value;
		///
		bool tailingComma;
		///
		bool singleLine;
		
		///
		ref Dictionary!(JsonKey, JsonValue).Item opIndex()(size_t idx) => value[idx];
		///
		ref JsonValue opIndex()(string key)
		{
			foreach (ref itm; value.byKeyValue)
			{
				if (itm.key.value[] == key)
					return itm.value;
			}
			throw new Exception(format("Key '%s' not found", key));
		}
		
		///
		alias value this;
	}
	///
	static struct JsonArray
	{
		///
		Array!JsonValue value;
		///
		bool tailingComma;
		///
		bool singleLine;
		
		///
		alias value this;
	}
	///
	enum UndefinedValue { init }
	///
	alias JsonType = SumType!(
		UndefinedValue,
		JsonString,
		JsonInteger,
		JsonUInteger,
		JsonFloatingPoint,
		bool,
		JsonArray,
		JsonObject,
		typeof(null));
	
	///
	static struct LineComment
	{
		///
		String value;
		///
		alias value this;
	}
	
	///
	static struct BlockComment
	{
		///
		Array!String value;
		///
		alias value this;
	}
	
	///
	static enum TrailingComment: LineComment { init = LineComment.init }
	
	///
	alias Comment = SumType!(
		LineComment,
		BlockComment,
		TrailingComment);
	
	///
	enum Type: ubyte
	{
		undefined,
		string,
		integer,
		uinteger,
		floating,
		boolean,
		array,
		object,
		nullfied,
	}
private:
	ref inout(Dictionary!(JsonKey, JsonValue)) _reqObj() pure inout @trusted
	{
		enum idx = staticIndexOf!(JsonObject, JsonType.Types);
		return __traits(getMember, _instance, "storage").tupleof[idx].value;
	}
	ref inout(Array!JsonValue) _reqArray() pure inout @trusted
	{
		enum idx = staticIndexOf!(JsonArray, JsonType.Types);
		return __traits(getMember, _instance, "storage").tupleof[idx].value;
	}
	ref inout(String) _reqStr() pure inout @trusted
	{
		enum idx = staticIndexOf!(JsonString, JsonType.Types);
		return __traits(getMember, _instance, "storage").tupleof[idx].value;
	}
	void _assignInst(T)(T v) @trusted
	{
		_instance = v;
	}
	
	Array!Comment _comments;
	JsonType _instance;
	Builder* _builder;
	this(scope ref Builder builder) @system pure nothrow @nogc
	{
		_builder = &builder;
	}
public:
	//##########################################################################
	//##### MARK: - - Constructor/Destructor/Assign
	//##########################################################################
	/***************************************************************************
	 * 
	 */
	this(T)(T val, scope ref Builder builder) pure return @system
	{
		_builder = &builder;
		opAssign(val);
	}
	
	/***************************************************************************
	 * 
	 */
	~this() pure nothrow @nogc @safe
	{
		if (_builder)
			_builder.dispose(this);
	}
	
	/***************************************************************************
	 * Assign operator
	 */
	ref JsonValue opAssign(T)(T value) pure return @trusted
	{
		alias U = Unqual!T;
		static if (is(T == JsonValue))
		{
			_builder  = value._builder;
			_comments = value._comments;
			_instance = value._instance;
		}
		else static if (is(U == StdJsonValue))
		{
			switch (value.type)
			{
			case StdJsonType.integer:   _instance = JsonInteger(value.integer);                 break;
			case StdJsonType.uinteger:  _instance = JsonUInteger(value.uinteger);               break;
			case StdJsonType.float_:    _instance = JsonFloatingPoint(value.floating);          break;
			case StdJsonType.true_:     _instance = true;                                       break;
			case StdJsonType.false_:    _instance = false;                                      break;
			case StdJsonType.null_:     _instance = null;                                       break;
			case StdJsonType.string:    _instance = JsonString(_builder.allocStr(value.str));   break;
			case StdJsonType.array:
				auto ary = _builder.allocAry!JsonValue;
				foreach (ref elm; value.array)
					ary ~= JsonValue(elm, *_builder);
				_instance = JsonArray(ary);
				break;
			case StdJsonType.object:
				auto tmp = _builder.allocDic!(JsonKey, JsonValue);
				foreach (ref k, ref v; value.object)
					tmp.append(JsonKey(_builder.allocStr(k)), JsonValue(v, *_builder));
				_instance = JsonObject(tmp);
				break;
			default:                    _instance = UndefinedValue.init;                        break;
			}
		}
		else static if (is(U == string))
		{
			auto tmp = JsonString(_builder.allocStr());
			tmp.value ~= value;
			_instance = tmp;
		}
		else static if (isSomeString!U)
		{
			import std.utf;
			auto tmp = JsonString(_builder.allocStr());
			tmp.value ~= value.toUTF8();
			_instance = tmp;
		}
		else static if (isIntegral!U && isSigned!U)
			_instance = JsonInteger(value);
		else static if (isIntegral!U && isUnsigned!U)
			_instance = JsonUInteger(value);
		else static if (isFloatingPoint!U)
			_instance = JsonFloatingPoint(value);
		else static if (isBoolean!U)
			_instance = value;
		else static if (is(U == typeof(null)))
			_instance = null;
		else static if (isArray!T)
		{
			auto ary = _builder.allocAry!JsonValue;
			foreach (ref v; value)
				ary ~= JsonValue(v, *_builder);
			_instance = JsonArray(ary);
		}
		else static if (isAssociativeArray!T && is(KeyType!T == string))
		{
			auto tmp = _builder.allocDic!(JsonKey, JsonValue);
			foreach (ref k, ref v; value)
				tmp.append(JsonKey(cast(String)k), JsonValue(v, *_builder));
			_instance = JsonObject(tmp);
		}
		else static if (is(T == JsonString))
			_instance = value;
		else static if (is(U == JsonInteger))
			_instance = value;
		else static if (is(U == JsonUInteger))
			_instance = value;
		else static if (is(U == JsonFloatingPoint))
			_instance = value;
		else static if (is(T == JsonArray))
			_instance = value;
		else static if (is(T == JsonObject))
			_instance = value;
		else static assert(0);
		return this;
	}
	
	/***************************************************************************
	 * 
	 */
	Type type() const nothrow pure @nogc @safe
	{
		return cast(Type)__traits(getMember, _instance, "tag");
	}
	
	//##########################################################################
	//##### MARK: - - Accessor
	//##########################################################################
	
	/***************************************************************************
	 * 
	 */
	ref inout(JsonString) asString() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.string, "Not a string type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.string];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(JsonInteger) asInteger() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.integer, "Not an integer number type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.integer];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(JsonUInteger) asUInteger() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.uinteger, "Not an unsigned integer number type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.uinteger];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(JsonFloatingPoint) asFloatingPoint() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.floating, "Not a floating point number type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.floating];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(bool) asBoolean() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.floating, "Not a floating point number type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.boolean];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(JsonObject) asObject() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.object, "Not an object type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.object];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(JsonArray) asArray() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.array, "Not an array type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.array];
	}
	
	/***************************************************************************
	 * Get value as the given type
	 * 
	 * If the type conversion is not possible, return the given default value (or T.init if not given).
	 */
	T get(T)(lazy T defaultValue = T.init) inout @safe
	{
		try
		{
			static if (is(T == string))
			{
				return _instance.match!(
					(in JsonString val) => val.value,
					(in _) => defaultValue);
			}
			else static if (isIntegral!T && isSigned!T)
			{
				return _instance.match!(
					(in JsonInteger val) => cast(T)val.value,
					(in JsonUInteger val) => cast(T)val.value,
					(in JsonFloatingPoint val) => cast(T)val.value,
					(in _) => defaultValue);
			}
			else static if (isIntegral!T && isUnsigned!T)
			{
				return _instance.match!(
					(in JsonUInteger val) => cast(T)val.value,
					(in JsonInteger val) => cast(T)val.value,
					(in JsonFloatingPoint val) => cast(T)val.value,
					(in _) => defaultValue);
			}
			else static if (isFloatingPoint!T)
			{
				return _instance.match!(
					(in JsonFloatingPoint val) => cast(T)val.value,
					(in JsonInteger val) => cast(T)val.value,
					(in JsonUInteger val) => cast(T)val.value,
					(in _) => defaultValue);
			}
			else static if (isBoolean!T)
			{
				return _instance.match!(
					(in bool val) => val,
					(in JsonInteger val) => val.value != 0,
					(in JsonUInteger val) => val.value != 0,
					(in JsonString val) => val.value != "",
					(in _) => defaultValue);
			}
			else static if (is(T == typeof(null)))
			{
				return _instance.match!(
					(in JsonString val) => val.value.length == 0 ? null : defaultValue,
					(in JsonArray val) => val.value.length == 0 ? null : defaultValue,
					(in JsonObject val) => val.value.byKeyValue.empty ? null : defaultValue,
					(in _) => defaultValue);
			}
			else static if (isDynamicArray!T)
			{
				return _instance.match!(
					(in JsonArray val) {
						T ret;
						foreach (ref elm; val.value)
							ret ~= elm.get!(ElementType!T)();
						return ret;
					},
					(in _) => defaultValue);
			}
			else static if (isAssociativeArray!T && is(KeyType!T == string))
			{
				return _instance.match!(
					(in JsonObject val) {
						T ret;
						foreach (ref kv; val.value.byKeyValue)
							ret[kv.key.value] = kv.value.get!(ValueType!T)();
						return ret;
					},
					(in _) => defaultValue);
			}
			else static if (is(T == JsonString))
				return _instance.match!(
					(in JsonString val) => val,
					(in _) => defaultValue);
			else static if (is(T == JsonInteger))
				return _instance.match!(
					(in JsonInteger val) => val,
					(in _) => defaultValue);
			else static if (is(T == JsonUInteger))
				return _instance.match!(
					(in JsonUInteger val) => val,
					(in _) => defaultValue);
			else static if (is(T == JsonFloatingPoint))
				return _instance.match!(
					(in JsonFloatingPoint val) => val,
					(in _) => defaultValue);
			else static if (is(T == JsonArray))
				return _instance.match!(
					(in JsonArray val) => val,
					(in _) => defaultValue);
			else static if (is(T == JsonObject))
				return _instance.match!(
					(in JsonObject val) => val,
					(in _) => defaultValue);
			else static assert(0);
		}
		catch (Exception e1)
		{
			try return defaultValue;
			catch (Exception e2)
				assert(0);
		}
		return T.init;
	}
	/// ditto
	T getValue(T)(string key, lazy T defaultValue = T.init) inout @safe
	{
		assert(type == Type.object, "Not an object type");
		try
		{
			foreach (ref kv; _reqObj.byKeyValue)
			{
				if (kv.key.value[] == key)
					return kv.value.get!T(defaultValue);
			}
			return defaultValue;
		}
		catch (Exception e)
		{
			try return defaultValue;
			catch (Exception e2)
				return T.init;
		}
		assert(0);
	}
	/// ditto
	T getElement(T)(size_t idx, lazy T defaultValue = T.init) inout @safe
	{
		assert(type == Type.array, "Not an array type");
		try
		{
			if (idx < _reqArray.length)
				return _reqArray[idx].get!T(defaultValue);
			return defaultValue;
		}
		catch (Exception e)
		{
			try return defaultValue;
			catch (Exception e2)
				return T.init;
		}
		assert(0);
	}
	
	/***************************************************************************
	 * Get number of comments
	 */
	size_t getCommentLength() const @safe
	{
		return _comments.length;
	}
	
	/***************************************************************************
	 * Add a line comment/block comment/trailing comment
	 */
	void addComment(in char[] comment, CommentType type = CommentType.line)
	{
		final switch (type)
		{
		case CommentType.line:
			addLineComment(comment);
			break;
		case CommentType.block:
			addBlockComment(comment);
			break;
		case CommentType.trailing:
			addTrailingComment(comment);
			break;
		}
	}
	/// ditto
	void addLineComment(in char[] comment) @safe
	{
		auto c = _builder.allocStr();
		c ~= comment;
		_comments ~= JsonValue.Comment(JsonValue.LineComment(c));
	}
	/// ditto
	void addBlockComment(in char[] comment) @safe
	{
		return addBlockComment(comment.splitLines());
	}
	/// ditto
	void addBlockComment(in const(char)[][] commentLines) @safe
	{
		auto blkComment = _builder.allocAry!String;
		foreach (line; commentLines)
		{
			auto c = _builder.allocStr();
			c ~= line;
			blkComment ~= c;
		}
		_comments ~= JsonValue.Comment(JsonValue.BlockComment(blkComment));
	}
	/// ditto
	void addTrailingComment(in char[] comment) @safe
	{
		auto c = _builder.allocStr();
		c ~= comment;
		_comments ~= JsonValue.Comment(JsonValue.TrailingComment(c));
	}
	
	/***************************************************************************
	 * Clear all comments
	 */
	void clearComment() @safe
	{
		_builder.clearAry(_comments);
	}
	
	/***************************************************************************
	 * Check if the comment at the given index is a line comment/block/trailing comment
	 */
	bool isLineComment(size_t idx) const @safe
	{
		assert(idx < _comments.length, "Comment index out of range");
		return __traits(getMember, _comments[idx], "tag") == 0;
	}
	/// ditto
	bool isBlockComment(size_t idx) const @safe
	{
		assert(idx < _comments.length, "Comment index out of range");
		return __traits(getMember, _comments[idx], "tag") == 1;
	}
	/// ditto
	bool isTrailingComment(size_t idx) const @safe
	{
		assert(idx + 1 == _comments.length, "Trailing comment index must be the last one");
		return __traits(getMember, _comments[idx], "tag") == 2;
	}
	/// ditto
	bool hasTrailingComment() const @safe
	{
		if (_comments.length == 0)
			return false;
		return isTrailingComment(size_t(_comments.length) - 1);
	}
	
	/***************************************************************************
	 * Reference comment as a line comment
	 */
	ref inout(LineComment) asLineComment(size_t index) inout @trusted
	{
		assert(index < _comments.length, "Comment index out of range");
		assert(isLineComment(index));
		return __traits(getMember, _comments[index], "storage").tupleof[0];
	}
	
	/***************************************************************************
	 * Reference comment as a block comment
	 */
	ref inout(BlockComment) asBlockComment(size_t index) inout @trusted
	{
		assert(index < _comments.length, "Comment index out of range");
		assert(isBlockComment(index));
		return __traits(getMember, _comments[index], "storage").tupleof[1];
	}
	
	/***************************************************************************
	 * Reference comment as a block comment
	 */
	ref inout(TrailingComment) asTrailingComment(size_t index) inout @trusted
	{
		assert(index + 1 == _comments.length, "Trailing comment index must be the last one");
		assert(isTrailingComment(index));
		return __traits(getMember, _comments[index], "storage").tupleof[2];
	}
	
	/***************************************************************************
	 * Get all comments as a single string
	 */
	string getComment(size_t index) const @safe
	{
		auto app = appender!(const(char)[][])();
		_comments[index].match!(
			(ref const(LineComment) line) => app ~= line.value[],
			(ref const(BlockComment) lines) {
				if (lines.value.length == 0)
					return;
				foreach (index, line; lines[])
				{
					if (index == 0)
					{
						if (line[].length == 0)
							continue;
					}
					if (index == size_t(lines.value.length) - 1)
					{
						auto tmp = line[].stripRight();
						if (tmp.length == 0)
							continue;
						app ~= tmp;
					}
					else
					{
						app ~= line[];
					}
				}
			},
			(ref const(TrailingComment) line) => app ~= line.value[]);
		return join((() @trusted => cast(string[])app.data)(), "\n").outdent;
	}
	/// ditto
	string getComments() const @safe
	{
		auto app = appender!(const(char)[][])();
		foreach (ref c; _comments[])
		{
			c.match!(
				(ref const(LineComment) line) => app ~= line.value[],
				(ref const(BlockComment) lines) {
					foreach (index, line; lines.value[])
					{
						if (index == 0)
						{
							if (line[].length == 0)
								continue;
						}
						if (index == size_t(lines.value.length) - 1)
						{
							auto tmp = line[].stripRight();
							if (tmp.length == 0)
								continue;
							app ~= tmp;
						}
						else
						{
							app ~= line[];
						}
					}
				},
				(ref const(TrailingComment) line) => app ~= line.value[]);
		}
		return join((() @trusted => cast(string[])app.data)(), "\n").outdent;
	}
	
	/***************************************************************************
	 * 
	 */
	StdJsonValue toStdJson() const @safe
	{
		StdJsonValue ret;
		_instance.match!(
			(ref const(UndefinedValue) val) @trusted { },
			(ref const(JsonString) val) @trusted { ret = StdJsonValue(val.value); },
			(ref const(JsonInteger) val) @trusted { ret = StdJsonValue(val.value); },
			(ref const(JsonUInteger) val) @trusted { ret = StdJsonValue(val.value); },
			(ref const(JsonFloatingPoint) val) @trusted { ret = StdJsonValue(val.value); },
			(ref const(bool) val) @trusted { ret = StdJsonValue(val); },
			(ref const(JsonArray) val) @trusted {
				ret = StdJsonValue.emptyArray;
				foreach (i, ref e; val.value[])
					ret.array ~= e.toStdJson();
			},
			(ref const(JsonObject) val) @trusted {
				ret = StdJsonValue.emptyObject;
				foreach (i, ref itm; val.value.byKeyValue)
					ret.object[itm.key.value] = itm.value.toStdJson();
			},
			(ref const(typeof(null)) val) @trusted { ret = StdJsonValue(null); });
		return ret;
	}
}

//##############################################################################
//##### MARK: Builder
//##############################################################################

/*******************************************************************************
 * 
 */
struct Json5BuilderImpl(alias allocator = Json5DefaultAllocator)
{
private:
	mixin Json5DefaultAllocator!();
	///
	alias Json5Builder = Json5BuilderImpl;
public:
	//##########################################################################
	//##### MARK: - - Builder Types
	//##########################################################################
	///
	alias JsonValue = .JsonValue!Json5Builder;
	///
	alias JsonType = JsonValue.Type;
	/// ditto
	alias JsonKey = JsonValue.JsonKey;
	/// ditto
	alias JsonString = JsonValue.JsonString;
	/// ditto
	alias JsonInteger = JsonValue.JsonInteger;
	/// ditto
	alias JsonUInteger = JsonValue.JsonUInteger;
	/// ditto
	alias JsonBoolean = bool;
	/// ditto
	alias JsonNullType = typeof(null);
	/// ditto
	alias JsonFloatingPoint = JsonValue.JsonFloatingPoint;
	/// ditto
	alias JsonObject = JsonValue.JsonObject;
	/// ditto
	alias JsonArray = JsonValue.JsonArray;
	
	//##########################################################################
	//##### MARK: - - Builder Factory
	//##########################################################################
	
	/***************************************************************************
	 * Create a JsonValue from a given value.
	 */
	JsonValue make(T)(T v) @trusted
	{
		return JsonValue(v, this);
	}
	
	/***************************************************************************
	 * Dispose the given JsonValue
	 */
	void dispose(ref JsonValue v) pure nothrow @nogc @safe
	{
		cast(void)v;
	}
	
	/***************************************************************************
	 * Create a JsonValue of null.
	 */
	JsonValue undefinedValue() pure nothrow @trusted
	{
		return JsonValue(this);
	}
	
	/***************************************************************************
	 * Create a JsonValue of empty array.
	 */
	JsonValue emptyArray() pure nothrow @trusted
	{
		return JsonValue(JsonValue.JsonArray.init, this);
	}
	
	/***************************************************************************
	 * Create a JsonValue of empty object.
	 */
	JsonValue emptyObject() pure nothrow @trusted
	{
		return JsonValue(JsonValue.JsonObject.init, this);
	}
	
	/***************************************************************************
	 * Create a JsonValue of null.
	 */
	JsonValue nullValue() pure nothrow @trusted
	{
		return JsonValue(null, this);
	}
	
	/***************************************************************************
	 * Deep copy
	 */
	JsonValue deepCopy(in JsonValue src) pure nothrow @safe
	{
		auto ret = src._instance.match!(
			(ref const(JsonArray) ary) @trusted
			{
				auto dst = allocAry!JsonValue;
				foreach (ref e; ary[])
					dst ~= deepCopy(e);
				return JsonValue(JsonArray(dst, ary.tailingComma, ary.singleLine), this);
			},
			(ref const(JsonObject) obj) @trusted
			{
				auto dst = allocDic!(JsonKey, JsonValue);
				foreach (ref e; obj.byKeyValue)
					dst.append(JsonKey(copyStr(e.key.value), e.key.quotedStyle), deepCopy(e.value));
				return JsonValue(JsonObject(dst), this);
			},
			(ref const(JsonString) str) @trusted => JsonValue(JsonString(copyStr(str), str.singleQuoted), this),
			(ref const(JsonUInteger) num) @trusted => JsonValue(num, this),
			(ref const(JsonInteger) num) @trusted => JsonValue(num, this),
			(ref const(JsonFloatingPoint) num) @trusted => JsonValue(num, this),
			(ref const(JsonBoolean) b) @trusted => JsonValue(b, this),
			(ref const(JsonNullType) n) @trusted => JsonValue(cast()n, this),
			(ref const(JsonValue.UndefinedValue) _) @trusted => undefinedValue()
		);
		alias Comment         = JsonValue.Comment;
		alias LineComment     = JsonValue.LineComment;
		alias BlockComment    = JsonValue.BlockComment;
		alias TrailingComment = JsonValue.TrailingComment;
		ret._comments = allocAry!Comment();
		foreach (ref comment; src._comments[])
		{
			ret._comments ~= comment.match!(
				(ref const(LineComment) c) => Comment(LineComment(copyStr(c.value))),
				(ref const(BlockComment) bc){
					BlockComment tmp;
					foreach (ref c; bc.value[])
						tmp.value ~= copyStr(c);
					return Comment(bc);
				},
				(ref const(TrailingComment) c) => Comment(TrailingComment(copyStr(c.value))),
			);
		}
		return ret;
	}
	
	//##########################################################################
	//##### MARK: - - JSON Perser
	//##########################################################################
	
	private size_t parseStringImpl(ref JsonValue.JsonString dst, in char[] src,
		ref size_t line, ref size_t col) @safe
	{
		// JSON5 double-quoted string parser
		assert(src.length > 0 && src[0] == '"', "Invalid source string");
		size_t i = 1;
		auto str = allocStr();
		
		while (i < src.length)
		{
			char c = src[i];
			if (c == '"')
			{
				i++;
				break;
			}
			else if (c == '\\')
			{
				i++;
				enforce(i < src.length, "Unexpected end after escape");
				c = src[i];
				switch (c)
				{
				case '"':  str ~= '"';  break;
				case '\\': str ~= '\\'; break;
				case '/':  str ~= '/';  break;
				case 'b':  str ~= '\b'; break;
				case 'f':  str ~= '\f'; break;
				case 'n':  str ~= '\n'; break;
				case 'r':  str ~= '\r'; break;
				case 't':  str ~= '\t'; break;
				case 'v':  str ~= '\v'; break;
				case '0':  str ~= '\0'; break;
				case 'u':
					import std.utf: encode;
					enforce(i + 4 < src.length, "Incomplete unicode escape");
					auto unichar = cast(dchar)to!int(src[i+1 .. i+5], 16);
					char[4] unistrbuf;
					str ~= unistrbuf[0..encode(unistrbuf, unichar)];
					i += 4;
					break;
				case '\n', '\r':
					// Line continuation, skip
					if (c == '\r' && i + 1 < src.length && src[i+1] == '\n')
						i++;
					line++;
					col = 1;
					break;
				default:
					str ~= c;
				}
			}
			else if (c == '\n' || c == '\r')
			{
				if (c == '\r' && i + 1 < src.length && src[i+1] == '\n')
					i++;
				str ~= '\n';
				line++;
				col = 1;
			}
			else
			{
				str ~= c;
			}
			i++;
			col++;
		}
		dst = JsonValue.JsonString(str, false);
		return i;
	}

	private size_t parseStringSingleQuoteImpl(ref JsonValue.JsonString dst, in char[] src,
		ref size_t line, ref size_t col) @safe
	{
		// JSON5 single-quoted string parser
		assert(src.length > 0 && src[0] == '\'', "Invalid source string");
		size_t i = 1;
		auto str = allocStr();
		
		while (i < src.length)
		{
			char c = src[i];
			if (c == '\'')
			{
				i++;
				break;
			}
			else if (c == '\\')
			{
				i++;
				enforce(i < src.length, "Unexpected end after escape");
				c = src[i];
				switch (c)
				{
				case '\'': str ~= '\''; break;
				case '\\': str ~= '\\'; break;
				case '/':  str ~= '/';  break;
				case 'b':  str ~= '\b'; break;
				case 'f':  str ~= '\f'; break;
				case 'n':  str ~= '\n'; break;
				case 'r':  str ~= '\r'; break;
				case 't':  str ~= '\t'; break;
				case 'v':  str ~= '\v'; break;
				case '0':  str ~= '\0'; break;
				case 'u':
					import std.utf: encode;
					enforce(i + 4 < src.length, "Incomplete unicode escape");
					auto unichar = cast(dchar)to!int(src[i+1 .. i+5], 16);
					char[4] unistrbuf;
					str ~= unistrbuf[0..encode(unistrbuf, unichar)];
					i += 4;
					break;
				case '\n', '\r':
					if (c == '\r' && i + 1 < src.length && src[i+1] == '\n')
						i++;
					line++;
					col = 1;
					break;
				default:
					str ~= c;
				}
			}
			else if (c == '\n' || c == '\r')
			{
				if (c == '\r' && i + 1 < src.length && src[i+1] == '\n')
					i++;
				str ~= '\n';
				line++;
				col = 1;
			}
			else
			{
				str ~= c;
			}
			i++;
			col++;
		}
		dst = JsonValue.JsonString(str, true);
		return i;
	}
	private size_t parseNumberImpl(ref JsonValue dst, in char[] src) @safe
	{
		import std.ascii: isDigit, isHexDigit;
		
		size_t originalIndex = 0;
		size_t index = 0;
		bool hasDecimal = false;
		bool hasExponent = false;
		bool leadingDecimal = false;
		bool trailingDecimal = false;
		assert(index < src.length, "Empty source string");
		
		// Handle sign
		if (src[index] == '+' || src[index] == '-')
			index++;
		
		// 16進数解析
		if (index + 1 < src.length && src[index] == '0' && (src[index + 1] == 'x' || src[index + 1] == 'X'))
		{
			index += 2;
			
			size_t start_index = index;
			while (index < src.length && isHexDigit(src[index]))
				index++;
			assert(index != start_index, "Invalid value: No hex digits found.");
			
			auto hex_str = src[start_index .. index];
			enforce(hex_str.length <= 16, "Hex number too large");
			
			auto hex_value = std.conv.parse!ulong(hex_str, 16);
			if (hex_value <= long.max)
			{
				auto hexVal = JsonValue.JsonInteger(cast(long)hex_value);
				hexVal.hex = true;
				hexVal.positiveSign = src[originalIndex] == '+';
				dst._assignInst(hexVal);
			}
			else
			{
				auto hexVal = JsonValue.JsonUInteger(cast(long)hex_value);
				hexVal.hex = true;
				hexVal.positiveSign = src[originalIndex] == '+';
				dst._assignInst(hexVal);
			}
			return index;
		}
		// 10進数解析
		size_t start_index = index;
		size_t decimal_pos = 0;
		size_t precision = 0;
		
		if (index < src.length && src[index] == '.')
			leadingDecimal = true;
		while (index < src.length)
		{
			if (isDigit(src[index]))
			{
				index++;
				// Count digits after decimal
				if (hasDecimal)
					precision++;
			}
			else if (src[index] == '.')
			{
				enforce(!hasExponent, "Invalid value: Multiple decimal points.");
				hasDecimal = true;
				decimal_pos = index;
				index++;
				// Reset precision after decimal
				precision = 0;
			}
			else if (src[index] == 'e' || src[index] == 'E')
			{
				enforce(!hasExponent, "Invalid value: Multiple exponents.");
				hasExponent = true;
				index++;
				// Check for sign after exponent
				if (index < src.length && (src[index] == '+' || src[index] == '-'))
					index++;
				size_t exp_digits_start = index;
				while (index < src.length && isDigit(src[index]))
					index++;
				enforce(index != exp_digits_start, "Invalid value: No digits after exponent.");
				// Exponent implies not a trailing decimal point
				trailingDecimal = false;
				// 有効桁数を計算
				if (hasDecimal) {
					precision = index - decimal_pos - 1;
					// 小数点の後に指数部があれば、その分は除外
					if (hasExponent)
						precision = exp_digits_start - decimal_pos - 1;
				}
				// Stop parsing number part after exponent
				break;
			}
			else
			{
				trailingDecimal = hasDecimal && index == decimal_pos + 1;
				break;
			}
		}
		
		assert(index != start_index, "Invalid value: No digits found at all");
		
		auto num_str = src[start_index .. index];
		if (hasDecimal || hasExponent)
		{
			auto val = JsonValue.JsonFloatingPoint(std.conv.parse!double(num_str));
			val.leadingDecimalPoint = leadingDecimal;
			val.tailingDecimalPoint = trailingDecimal;
			val.withExponent = hasExponent;
			val.precision = precision;
			val.positiveSign = src[originalIndex] == '+';
			dst._assignInst(val);
		}
		else
		{
			if (src[originalIndex] == '-')
			{
				enforce(num_str.length <= 19, "Invalid value: Negative number too large");
				dst._assignInst(JsonValue.JsonInteger(std.conv.parse!long(num_str)));
			}
			else
			{
				enforce(num_str.length <= 20, "Invalid value: Number too large");
				auto num_value = std.conv.parse!ulong(num_str);
				if (num_value <= long.max)
				{
					auto val = JsonValue.JsonInteger(cast(long)num_value);
					val.hex = false;
					val.positiveSign = src[originalIndex] == '+';
					dst._assignInst(val);
				}
				else
				{
					auto val = JsonValue.JsonUInteger(num_value);
					val.hex = false;
					val.positiveSign = src[originalIndex] == '+';
					dst._assignInst(val);
				}
			}
		}
		return index;
	}
	
	private size_t parseLineCommentImpl(ref JsonValue.LineComment dst, in char[] src) @safe
	{
		// Parse JSON5 line comment starting with `//`
		assert(src.length >= 2 && src[0] == '/' && src[1] == '/', "Invalid line comment");
		
		size_t i = 2;
		auto comment = allocStr();
		while (i < src.length)
		{
			char c = src[i];
			if (c == '\n' || c == '\r')
				break;
			comment ~= c;
			i++;
		}
		dst.value = comment;
		return i;
	}
	
	private size_t parseBlockCommentImpl(ref JsonValue.BlockComment dst, in char[] src,
		ref size_t line, ref size_t col) @safe
	{
		// Parse JSON5 block comment starting with `/*`
		assert(src.length >= 2 && src[0] == '/' && src[1] == '*', "Invalid block comment");
		
		size_t index = 2;
		auto commentLines = allocAry!String;
		auto currentLine = allocStr();
		
		while (index < src.length)
		{
			char c = src[index];
			// Check for end of block comment
			if (c == '*' && index + 1 < src.length && src[index + 1] == '/')
			{
				index += 2;
				break;
			}
			else if (c == '/' && index + 1 < src.length && src[index + 1] == '*')
			{
				// Nested block comment
				JsonValue.BlockComment nested;
				size_t parsedLen = parseBlockCommentImpl(nested, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse nested block comment at index %d (line = %d, column = %d)",
					index, line, col));
				auto nestedLiens = src[index .. index + parsedLen].splitLines;
				foreach (ref l; nestedLiens[0..$ - 1])
				{
					currentLine ~= l;
					commentLines ~= currentLine;
					currentLine = allocStr();
				}
				currentLine ~= nestedLiens[$ - 1];
				index += parsedLen;
				assert(index >= 4 && src[index - 2] == '*' && src[index - 1] == '/',
					"Nested block comment did not end properly");
			}
			else if (c == '\n' || c == '\r')
			{
				commentLines ~= currentLine;
				currentLine = allocStr();
				if (c == '\r' && index + 1 < src.length && src[index + 1] == '\n')
					index++;
				line++;
				col = 1;
			}
			else
			{
				currentLine ~= c;
				col++;
			}
			index++;
		}
		commentLines ~= currentLine;
		dst.value = commentLines;
		return index;
	}
	
	private size_t parseTrailingCommentImpl(ref JsonValue.TrailingComment dst, in char[] src) @safe
	{
		// Parse JSON5 trailing comment starting with `\s+//`
		size_t index = 0;
		// Check for trailing comment
		while (index < src.length)
		{
			switch (src[index])
			{
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				// skip whitespace
				index++;
				break;
			case '/':
				// Check for trailing comment
				if (index + 1 < src.length && src[index + 1] == '/')
				{
					JsonValue.LineComment lc;
					size_t parsedLen = parseLineCommentImpl(lc, src[index..$]);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d", index));
					dst.value = lc.value;
					index = index + parsedLen;
					return index;
				}
				else if (index + 1 < src.length && src[index + 1] == '*')
				{
					JsonValue.BlockComment bc;
					size_t dummyLine, dummyCol;
					size_t parsedLen = parseBlockCommentImpl(bc, src[index..$], dummyLine, dummyCol);
					enforce(parsedLen > 0,
						format("Failed to parse block comment at index %d", index));
					if (dummyLine > 0)
					{
						// Block comment contains new lines, not a trailing comment
						return 0;
					}
					dst.value = bc.value[0];
					index = index + parsedLen;
					return index;
				}
				else
				{
					return 0;
				}
			default:
				// end of value
				return 0;
			}
		}
		return 0;
	}
	private size_t parseObjectKeyValueImpl(ref JsonValue.JsonKey dstKey, ref JsonValue dstValue,
		in char[] src, ref size_t line, ref size_t col) @safe
	{
		// srcは必ずキーの先頭
		size_t index = 0;
		col++;
		void trailingCommentCheck(ref JsonValue dstVal)
		{
			JsonValue.TrailingComment trailingComment;
			auto trailingCommentLen = parseTrailingCommentImpl(trailingComment, src[index..$]);
			if (trailingCommentLen > 0)
			{
				dstVal._comments ~= JsonValue.Comment(trailingComment);
				index += trailingCommentLen;
				col   += trailingCommentLen;
			}
		}
		void commentCheck(ref JsonValue dstVal)
		{
			if (index + 1 < src.length && src[index + 1] == '/')
			{
				JsonValue.LineComment lc;
				size_t parsedLen = parseLineCommentImpl(lc, src[index..$]);
				enforce(parsedLen > 0,
					format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
				dstValue._comments ~= JsonValue.Comment(lc);
				index += parsedLen;
				col   += parsedLen;
			}
			else if (index + 1 < src.length && src[index + 1] == '*')
			{
				JsonValue.BlockComment bc;
				size_t parsedLen = parseBlockCommentImpl(bc, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse block comment at index %d (line = %d, column = %d)", index, line, col));
				dstValue._comments ~= JsonValue.Comment(bc);
				index += parsedLen;
			}
			else
			{
				enforce(false,
					format("Unexpected '/' when parsing object key %d (line = %d, column = %d)", index, line, col));
			}
		}
		// キー解析
		if (src[index] == '"')
		{
			JsonValue.JsonString tmpKey;
			size_t parsedLen = parseStringImpl(tmpKey, src[index..$], line, col);
			enforce(parsedLen > 0, "Failed to parse double-quoted key");
			dstKey = JsonValue.JsonKey(tmpKey.value, QuotedStyle.doubleQuoted);
			index += parsedLen;
			col   += parsedLen;
		}
		else if (src[index] == '\'')
		{
			JsonValue.JsonString tmpKey;
			size_t parsedLen = parseStringSingleQuoteImpl(tmpKey, src[index..$], line, col);
			enforce(parsedLen > 0, "Failed to parse single-quoted key");
			dstKey = JsonValue.JsonKey(tmpKey.value, QuotedStyle.singleQuoted);
			index += parsedLen;
			col   += parsedLen;
		}
		else
		{
			// Unquoted key (identifier)
			size_t start = index;
			while (index < src.length && (
				(src[index] >= 'a' && src[index] <= 'z') ||
				(src[index] >= 'A' && src[index] <= 'Z') ||
				(src[index] >= '0' && src[index] <= '9') ||
				src[index] == '_' || src[index] == '$'))
			{
				index++;
				col++;
			}
			enforce(index > start, "Invalid object key");
			auto keyStr = allocStr();
			keyStr ~= src[start .. index];
			dstKey = JsonValue.JsonKey(keyStr, QuotedStyle.unquoted);
		}
		// コロンを探す
		while (index < src.length && src[index] != ':')
		{
			switch (src[index])
			{
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				index++;
				col++;
				break;
			case '\n', '\r':
				if (src[index] == '\r' && index + 1 < src.length && src[index + 1] == '\n')
					index++;
				index++;
				line++;
				col = 1;
				break;
			case '/':
				commentCheck(dstValue);
				break;
			default:
				enforce(false, "Expected ':' after object key");
			}
		}
		enforce(index < src.length && src[index] == ':', "Expected ':' after object key");
		index++;
		col++;
		
		// 値解析
		while (index < src.length)
		{
			// 値の先頭からparseを呼ぶ
			switch (src[index])
			{
			case '{':
				size_t parsedLen = parseObjectImpl(dstValue, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse object at index %d (line = %d, column = %d)", index, line, col));
				index += parsedLen;
				trailingCommentCheck(dstValue);
				return index;
			case '[':
				size_t parsedLen = parseArrayImpl(dstValue, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse array at index %d (line = %d, column = %d)", index, line, col));
				index += parsedLen;
				trailingCommentCheck(dstValue);
				return index;
			case '"':
				JsonValue.JsonString tmpStr;
				size_t parsedLen = parseStringImpl(tmpStr, src[index..$], line, col);
				enforce(parsedLen > 0, "Failed to parse string at ");
				dstValue._assignInst(tmpStr);
				index += parsedLen;
				trailingCommentCheck(dstValue);
				return index;
			case '\'':
				JsonValue.JsonString tmpStr;
				size_t parsedLen = parseStringSingleQuoteImpl(tmpStr, src[index..$], line, col);
				dstValue._assignInst(tmpStr);
				index += parsedLen;
				trailingCommentCheck(dstValue);
				return index;
			case '/':
				commentCheck(dstValue);
				break;
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				index++;
				col++;
				break;
			case '\n', '\r':
				index++;
				line++;
				col = 1;
				break;
			case '-', '+', '.', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'I', 'N':
				size_t parsedLen = parseNumberImpl(dstValue, src[index..$]);
				enforce(parsedLen > 0,
					format("Failed to parse number at index %d (line = %d, column = %d)", index, line, col));
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck(dstValue);
				return index;
			case 'n':
				enforce(src[index..$].startsWith("null"), "Unexpected token for value");
				dstValue._assignInst(null);
				index += 4;
				col   += 4;
				trailingCommentCheck(dstValue);
				return index;
			case 't':
				enforce(src[index..$].startsWith("true"), "Unexpected token for value");
				dstValue._assignInst(true);
				index += 4;
				col   += 4;
				trailingCommentCheck(dstValue);
				return index;
			case 'f':
				enforce(src[index..$].startsWith("false"), "Unexpected token for value");
				dstValue._assignInst(false);
				index += 5;
				col   += 5;
				trailingCommentCheck(dstValue);
				return index;
			default:
				enforce(false, "Unexpected token for value");
			}
		}
		return index;
	}
	
	private size_t parseObjectImpl(ref JsonValue dst, in char[] src, ref size_t line, ref size_t col) @safe
	{
		// Parse JSON5 object starting with `{`
		assert(src.length >= 1 && src[0] == '{', "Invalid json object");
		size_t index = 1;
		col++;
		bool expectKey = true;
		bool expectComma = false;
		bool tailingComma = false;
		bool singleLineObject = true;
		
		// Create empty object
		auto obj = allocDic!(JsonValue.JsonKey, JsonValue);
		void trailingCommentCheck(ref JsonValue dstValue)
		{
			if (dstValue.hasTrailingComment)
				return;
			JsonValue.TrailingComment trailingComment;
			auto trailingCommentLen = parseTrailingCommentImpl(trailingComment, src[index..$]);
			if (trailingCommentLen > 0)
			{
				dstValue._comments ~= JsonValue.Comment(trailingComment);
				index += trailingCommentLen;
				col   += trailingCommentLen;
			}
		}
		JsonValue.JsonKey currKey = JsonValue.JsonKey.init;
		JsonValue currValue = undefinedValue();
		
		while (index < src.length)
		{
			switch (src[index])
			{
			case '}':
				index++;
				col++;
				if (currValue.type != JsonValue.Type.undefined)
					obj.append(currKey, currValue);
				dst._assignInst(JsonValue.JsonObject(obj, tailingComma, singleLineObject));
				trailingCommentCheck(dst);
				return index;
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				// skip whitespace
				index++;
				col++;
				break;
			case '\n', '\r':
				// skip newline
				index++;
				if (src[index - 1] == '\r' && index < src.length && src[index] == '\n')
					index++;
				line++;
				col = 1;
				singleLineObject = false;
				if (currValue.type != JsonValue.Type.undefined)
				{
					// Trailing comment has ended the value
					obj.append(currKey, currValue);
					currKey = JsonValue.JsonKey.init;
					currValue = undefinedValue();
				}
				break;
			case '/':
				// Check for line comment
				if (index + 1 < src.length && src[index + 1] == '/')
				{
					JsonValue.LineComment lc;
					size_t parsedLen = parseLineCommentImpl(lc, src[index..$]);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
					assert(dst.type == JsonValue.Type.undefined);
					currValue._comments ~= JsonValue.Comment(lc);
					index += parsedLen;
					col   += parsedLen;
				}
				else if (index + 1 < src.length && src[index + 1] == '*')
				{
					JsonValue.BlockComment bc;
					size_t parsedLen = parseBlockCommentImpl(bc, src[index..$], line, col);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
					currValue._comments ~= JsonValue.Comment(bc);
					index += parsedLen;
					col   += parsedLen;
				}
				else
				{
					enforce(false, format("Unexpected '/' at index %d (line = %d, column = %d)", index, line, col));
				}
				break;
			default:
				// Parse key-value pair
				if (expectKey)
				{
					size_t parsedLen = parseObjectKeyValueImpl(currKey, currValue, src[index..$], line, col);
					enforce(parsedLen > 0,
						format("Failed to parse object key-value pair at index %d (line = %d, column = %d)", index, line, col));
					index += parsedLen;
					col   += parsedLen;
					expectKey = false;
					expectComma = true;
					tailingComma = false;
					trailingCommentCheck(currValue);
				}
				else if (expectComma)
				{
					if (src[index] == ',')
					{
						index++;
						col++;
						expectKey = true;
						expectComma = false;
						tailingComma = true;
						trailingCommentCheck(currValue);
						obj.append(currKey, currValue);
						currKey = JsonValue.JsonKey.init;
						currValue = undefinedValue();
					}
					else
					{
						enforce(false,
							format("Expected ',' at index %d (line = %d, column = %d)", index, line, col));
					}
				}
				else
				{
					enforce(false,
						format("Unexpected token at index %d (line = %d, column = %d)", index, line, col));
				}
			}
		}
		return index;
	}
	
	private size_t parseArrayElementImpl(ref JsonValue dst, in char[] src, ref size_t line, ref size_t col)
	{
		// srcは必ず値の先頭
		size_t index = 0;
		col++;
		void trailingCommentCheck(ref JsonValue dstVal)
		{
			JsonValue.TrailingComment trailingComment;
			auto trailingCommentLen = parseTrailingCommentImpl(trailingComment, src[index..$]);
			if (trailingCommentLen > 0)
			{
				dstVal._comments ~= JsonValue.Comment(trailingComment);
				index += trailingCommentLen;
				col   += trailingCommentLen;
			}
		}
		while (index < src.length)
		{
			switch (src[index])
			{
			case '{':
				size_t parsedLen = parseObjectImpl(dst, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse object at index %d (line = %d, column = %d)", index, line, col));
				index += parsedLen;
				trailingCommentCheck(dst);
				return index;
			case '[':
				size_t parsedLen = parseArrayImpl(dst, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse array at index %d (line = %d, column = %d)", index, line, col));
				index += parsedLen;
				trailingCommentCheck(dst);
				return index;
			case '"':
				JsonValue.JsonString tmpStr;
				size_t parsedLen = parseStringImpl(tmpStr, src[index..$], line, col);
				enforce(parsedLen > 0, "Failed to parse string at ");
				dst._assignInst(tmpStr);
				index += parsedLen;
				trailingCommentCheck(dst);
				return index;
			case '\'':
				JsonValue.JsonString tmpStr;
				size_t parsedLen = parseStringSingleQuoteImpl(tmpStr, src[index..$], line, col);
				enforce(parsedLen > 0, "Failed to parse single-quoted string");
				dst._assignInst(tmpStr);
				index += parsedLen;
				trailingCommentCheck(dst);
				return index;
			case '/':
				if (index + 1 < src.length && src[index + 1] == '/')
				{
					JsonValue.LineComment lc;
					size_t parsedLen = parseLineCommentImpl(lc, src[index..$]);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
					dst._comments ~= JsonValue.Comment(lc);
					index += parsedLen;
					col   += parsedLen;
				}
				else if (index + 1 < src.length && src[index + 1] == '*')
				{
					JsonValue.BlockComment bc;
					size_t parsedLen = parseBlockCommentImpl(bc, src[index..$], line, col);
					enforce(parsedLen > 0,
						format("Failed to parse block comment at index %d (line = %d, column = %d)", index, line, col));
					dst._comments ~= JsonValue.Comment(bc);
					index += parsedLen;
					col   += parsedLen;
				}
				else
				{
					enforce(false, format("Unexpected '/' at index %d (line = %d, column = %d)", index, line, col));
				}
				break;
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				index++;
				col++;
				break;
			case '\n', '\r':
				index++;
				if (src[index - 1] == '\r' && index < src.length && src[index] == '\n')
					index++;
				line++;
				col = 1;
				break;
			case '-', '+', '.', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'I', 'N':
				size_t parsedLen = parseNumberImpl(dst, src[index..$]);
				enforce(parsedLen > 0,
					format("Failed to parse number at index %d (line = %d, column = %d)", index, line, col));
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck(dst);
				return index;
			case 'n':
				enforce(src[index..$].startsWith("null"), "Unexpected token for value");
				dst._assignInst(null);
				index += 4;
				col   += 4;
				trailingCommentCheck(dst);
				return index;
			case 't':
				enforce(src[index..$].startsWith("true"), "Unexpected token for value");
				dst._assignInst(true);
				index += 4;
				col   += 4;
				trailingCommentCheck(dst);
				return index;
			case 'f':
				enforce(src[index..$].startsWith("false"), "Unexpected token for value");
				dst._assignInst(false);
				index += 5;
				col   += 5;
				trailingCommentCheck(dst);
				return index;
			default:
				enforce(false, "Unexpected token for value");
			}
		}
		return index;
	}
	
	private size_t parseArrayImpl(ref JsonValue dst, in char[] src, ref size_t line, ref size_t col) @safe
	{
		// Parse JSON5 object starting with `[`
		assert(src.length >= 1 && src[0] == '[', "Invalid json object");
		
		size_t index = 1;
		col++;
		bool expectValue = true;
		bool expectComma = false;
		bool tailingComma = false;
		bool singleLineObject = true;
		
		// Create empty object
		auto ary = allocAry!(JsonValue);
		void trailingCommentCheck(ref JsonValue dstValue)
		{
			JsonValue.TrailingComment trailingComment;
			auto trailingCommentLen = parseTrailingCommentImpl(trailingComment, src[index..$]);
			if (trailingCommentLen > 0)
			{
				dstValue._comments ~= JsonValue.Comment(trailingComment);
				index += trailingCommentLen;
				col   += trailingCommentLen;
			}
		}
		
		JsonValue currValue = undefinedValue();
		
		while (index < src.length)
		{
			switch (src[index])
			{
			case ']':
				index++;
				col++;
				if (currValue.type != JsonValue.Type.undefined)
					ary ~= currValue;
				dst._assignInst(JsonValue.JsonArray(ary, tailingComma, singleLineObject));
				trailingCommentCheck(dst);
				return index;
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				// skip whitespace
				index++;
				col++;
				break;
			case '\n', '\r':
				index++;
				if (src[index - 1] == '\r' && index < src.length && src[index] == '\n')
					index++;
				line++;
				singleLineObject = false;
				col = 1;
				if (currValue.type != JsonValue.Type.undefined)
				{
					ary ~= currValue;
					currValue = undefinedValue();
				}
				break;
			case '/':
				// Check for line comment
				if (index + 1 < src.length && src[index + 1] == '/')
				{
					JsonValue.LineComment lc;
					size_t parsedLen = parseLineCommentImpl(lc, src[index..$]);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
					currValue._comments ~= JsonValue.Comment(lc);
					index += parsedLen;
					col   += parsedLen;
				}
				else if (index + 1 < src.length && src[index + 1] == '*')
				{
					JsonValue.BlockComment bc;
					size_t parsedLen = parseBlockCommentImpl(bc, src[index..$], line, col);
					enforce(parsedLen > 0,
						format("Failed to parse block comment at index %d (line = %d, column = %d)", index, line, col));
					currValue._comments ~= JsonValue.Comment(bc);
					index += parsedLen;
					col   += parsedLen;
				}
				else
				{
					enforce(false, format("Unexpected '/' at index %d (line = %d, column = %d)", index, line, col));
				}
				break;
			default:
				if (expectValue)
				{
					// Parse value
					size_t parsedLen = parseArrayElementImpl(currValue, src[index..$], line, col);
					enforce(parsedLen > 0,
						format("Failed to parse array element at index %d (line = %d, column = %d)", index, line, col));
					index += parsedLen;
					col   += parsedLen;
					expectValue = false;
					expectComma = true;
					tailingComma = false;
					trailingCommentCheck(currValue);
				}
				else if (expectComma)
				{
					if (src[index] == ',')
					{
						index++;
						col++;
						expectValue = true;
						expectComma = false;
						tailingComma = true;
						trailingCommentCheck(currValue);
						ary ~= currValue;
						currValue = undefinedValue();
					}
					else
					{
						enforce(false, format("Expected ',' at index %d (line = %d, column = %d)", index, line, col));
					}
				}
				else
				{
					enforce(false, format("Unexpected token at index %d (line = %d, column = %d)", index, line, col));
				}
				break;
			}
		}
		
		return index;
	}
	
	/***************************************************************************
	 * Parse JSON string
	 */
	JsonValue parse(in char[] src) @safe
	{
		JsonValue ret = undefinedValue;
		size_t index = 0;
		size_t line  = 1;
		size_t col   = 1;
		
		void trailingCommentCheck()
		{
			JsonValue.TrailingComment trailingComment;
			auto trailingCommentLen = parseTrailingCommentImpl(trailingComment, src[index..$]);
			if (trailingCommentLen > 0)
			{
				ret._comments ~= JsonValue.Comment(trailingComment);
				index += trailingCommentLen;
				col   += trailingCommentLen;
			}
		}
		
		while (index < src.length)
		{
			switch (src[index])
			{
			case '{':
				size_t parsedLen = parseObjectImpl(ret, src[index..$], line, col);
				enforce(parsedLen > 0, format("Failed to parse object at index %s", index));
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck();
				continue;
			case '[':
				size_t parsedLen = parseArrayImpl(ret, src[index..$], line, col);
				enforce(parsedLen > 0, format("Failed to parse array at index %s", index));
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck();
				continue;
			case '"':
				JsonValue.JsonString tmpStr;
				size_t parsedLen = parseStringImpl(tmpStr, src[index..$], line, col);
				enforce(parsedLen > 0,
					format("Failed to parse string at index %d (line = %d, column = %d)", index, line, col));
				ret._assignInst(tmpStr);
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck();
				continue;
			case '\'':
				JsonValue.JsonString tmpStr;
				size_t parsedLen = parseStringSingleQuoteImpl(tmpStr, src[index..$], line, col);
				enforce(parsedLen > 0, format("Failed to parse single quote string at index %s", index));
				ret._assignInst(tmpStr);
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck();
				continue;
			case '/':
				// Check for line comment
				if (index + 1 < src.length && src[index + 1] == '/')
				{
					JsonValue.LineComment lc;
					size_t parsedLen = parseLineCommentImpl(lc, src[index..$]);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
					ret._comments ~= ret.type == JsonValue.Type.undefined
						? JsonValue.Comment(lc)
						: JsonValue.Comment(JsonValue.TrailingComment(lc.value));
					index += parsedLen;
					col   += parsedLen;
				}
				else if (index + 1 < src.length && src[index + 1] == '*')
				{
					JsonValue.BlockComment bc;
					size_t parsedLen = parseBlockCommentImpl(bc, src[index..$], line, col);
					enforce(parsedLen > 0,
						format("Failed to parse line comment at index %d (line = %d, column = %d)", index, line, col));
					ret._comments ~= JsonValue.Comment(bc);
					index += parsedLen;
					col   += parsedLen;
				}
				else
				{
					enforce(false, format("Unexpected '/' at index %d (line = %d, column = %d)", index, line, col));
				}
				continue;
			case ' ', '\t', '\v', '\f', '\u00A0', '\u2028', '\u2029', '\uFEFF':
				index++;
				col++;
				// Skip whitespace
				continue;
			case '\n', '\r':
				if (src[index] == '\r' && index + 1 < src.length && src[index + 1] == '\n')
				{
					line++;
					col = 1;
					index += 2;
				}
				else
				{
					line++;
					col = 1;
					index++;
				}
				continue;
			case '-', '+', '.', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'I', 'N':
				size_t parsedLen = parseNumberImpl(ret, src[index..$]);
				enforce(parsedLen > 0,
					format("Failed to parse numeric value at index %d (line=%d, column=%d)", index, line, col));
				index += parsedLen;
				col   += parsedLen;
				trailingCommentCheck();
				continue;
			case 'n':
				enforce(src[index..$].startsWith("null"),
					format("Unexpected token at index %d (line=%d, column=%d)", index, line, col));
				ret = make(null);
				index += 4;
				col   += 4;
				trailingCommentCheck();
				continue;
			case 't':
				enforce(src[index..$].startsWith("true"),
					format("Unexpected token at index %d (line=%d, column=%d)", index, line, col));
				ret = make(true);
				index += 4;
				col   += 4;
				trailingCommentCheck();
				continue;
			case 'f':
				enforce(src[index..$].startsWith("false"),
					format("Unexpected token at index %d (line=%d, column=%d)", index, line, col));
				ret = make(false);
				index += 5;
				col   += 5;
				trailingCommentCheck();
				continue;
			default:
				// Handle other JSON value types: numbers, booleans, null
				// This part needs more robust parsing logic for different value types.
				// For now, we'll just advance the index if it's not a recognized start character.
				// A full parser would need to look ahead to identify numbers, booleans, null, etc.
				index++;
				col++;
			}
		}
		return ret;
	}
	
	//##########################################################################
	//##### MARK: - - Stringify
	//##########################################################################
	
	/***************************************************************************
	 * Options for pretty-printing JSON
	 */
	enum JsonPrettyPrintOptions: uint
	{
		none = 0,
		escapeNonAscii = 1 << 0,
		escapeSlash    = 1 << 1,
	}
	private void _putPrettyStringJsonCommentImpl(OutputRange)(ref OutputRange dst,
		ref const(Array!(JsonValue.Comment)) comments,
		in char[] indent, in char[] newline, size_t indentLevel,
		JsonPrettyPrintOptions options, bool forceBlock = false) const
	{
		foreach (ref comment; comments)
		{
			comment.match!(
				(ref const(JsonValue.LineComment) lineComment) {
					if (forceBlock)
					{
						put(dst, indent.repeat(indentLevel));
						put(dst, "/*");
						put(dst, cast(string)lineComment.value[]);
						put(dst, "*/");
						put(dst, newline);
					}
					else
					{
						put(dst, indent.repeat(indentLevel));
						put(dst, "//");
						put(dst, cast(string)lineComment.value[]);
						put(dst, newline);
					}
				},
				(ref const(JsonValue.BlockComment) blockComment) {
					put(dst, indent.repeat(indentLevel));
					if (blockComment.value.length == 0)
					{
						put(dst, "/**/");
						put(dst, newline);
						return;
					}
					else if (blockComment.value.length == 1)
					{
						put(dst, "/*");
						put(dst, cast(string)blockComment.value[0]);
						put(dst, "*/");
						put(dst, newline);
						return;
					}
					else
					{
						put(dst, "/*");
						foreach (c; blockComment.value[])
						{
							put(dst, cast(string)c[]);
							put(dst, newline);
						}
						put(dst, "*/");
					}
				},
				(ref const _) {}
			);
		}
	}
	
	private void _putPrettyStringJsonTrailingCommentImpl(OutputRange)(ref OutputRange dst,
		ref const(Array!(JsonValue.Comment)) comments, bool blockType) const
	{
		if (comments.length == 0)
			return;
		comments[$ - 1].match!(
			(ref const(JsonValue.TrailingComment) trailingComment) {
				if (blockType)
				{
					put(dst, " /*");
					put(dst, cast(string)trailingComment.value[]);
					put(dst, "*/");
				}
				else
				{
					put(dst, " //");
					put(dst, cast(string)trailingComment.value[]);
				}
			},
			(_) {}
		);
	}
	
	private void _putPrettyStringJsonStringImpl(OutputRange)(ref OutputRange dst, ref const(JsonValue.JsonString) strVal,
		JsonPrettyPrintOptions options) const
	{
		import std.ascii: isASCII;
		import std.utf: byWchar, stride;
		
		char quote = strVal.singleQuoted ? '\'' : '"';
		put(dst, quote);
		size_t index = 0;
		while (index < strVal.value.length)
		{
			char c = strVal.value[index];
			bool escape = false;
			// Escape control characters and quotes
			switch (c)
			{
			case '"', '\'':
				if (c == quote)
				{
					put(dst, '\\');
					put(dst, c);
					escape = true;
				}
				break;
			case '\\':
				put(dst, "\\\\");
				escape = true;
				break;
			case '/':
				if (options & JsonPrettyPrintOptions.escapeSlash)
				{
					put(dst, "\\/");
					escape = true;
				}
				break;
			case '\b': put(dst, "\\b"); escape = true; break;
			case '\f': put(dst, "\\f"); escape = true; break;
			case '\n': put(dst, "\\n"); escape = true; break;
			case '\r': put(dst, "\\r"); escape = true; break;
			case '\t': put(dst, "\\t"); escape = true; break;
			case '\v': put(dst, "\\v"); escape = true; break;
			case '\0': put(dst, "\\0"); escape = true; break;
			default:
				if (options & JsonPrettyPrintOptions.escapeNonAscii && !isASCII(c))
				{
					// Convert to wchar and escape non-ASCII
					import std.utf : byWchar;
					auto cnt = stride(strVal.value, index);
					put(dst, format("\\u%04X", (cast(string)strVal.value[index .. index + cnt]).byWchar.front));
					index += cnt - 1; // -1 because index++ at the end
				}
				break;
			}
			if (!escape)
				put(dst, c);
			index++;
		}
		put(dst, quote);
	}
	
	private void _putPrettyStringJsonUIntegerImpl(OutputRange)(ref OutputRange dst,
		ref const(JsonValue.JsonUInteger) intVal) const
	{
		if (intVal.hex)
		{
			auto val = intVal.value;
			if (intVal.positiveSign)
				put(dst, "+");
			if (val <= 0xFF)
			{
				formattedWrite(dst, "0x%02X", val);
			}
			else if (val <= 0xFFFF)
			{
				formattedWrite(dst, "0x%04X", val);
			}
			else if (val <= 0xFFFFFFFFUL)
			{
				formattedWrite(dst, "0x%08X", val);
			}
			else
			{
				formattedWrite(dst, "0x%016X", val);
			}
		}
		else
		{
			if (intVal.positiveSign)
			{
				formattedWrite(dst, "%+d", intVal.value);
			}
			else
			{
				formattedWrite(dst, "%d", intVal.value);
			}
		}
	}
	private void _putPrettyStringJsonIntegerImpl(OutputRange)(ref OutputRange dst,
		ref const(JsonValue.JsonInteger) intVal) const
	{
		if (intVal.hex)
		{
			long val = intVal.value;
			if (val < 0)
			{
				put(dst, "-");
				val = -val;
			}
			else
			{
				if (intVal.positiveSign)
					put(dst, "+");
			}
			if (val <= 0xFF)
			{
				formattedWrite(dst, "0x%02X", val);
			}
			else if (val <= 0xFFFF)
			{
				formattedWrite(dst, "0x%04X", val);
			}
			else if (val <= 0xFFFFFFFFUL)
			{
				formattedWrite(dst, "0x%08X", val);
			}
			else
			{
				formattedWrite(dst, "0x%016X", val);
			}
		}
		else
		{
			if (intVal.positiveSign)
			{
				formattedWrite(dst, "%+d", intVal.value);
			}
			else
			{
				formattedWrite(dst, "%d", intVal.value);
			}
		}
	}
	
	private void _putPrettyStringJsonFloatingPointImpl(OutputRange)(ref OutputRange dst,
		ref const(JsonValue.JsonFloatingPoint) fpVal) const
	{
		char[64] buf;
		if (fpVal.withExponent)
		{
			if (fpVal.precision == 0)
			{
				auto valStrs = sformat(buf[], fpVal.positiveSign ? "%+e" : "%e", fpVal.value).split("e");
				// eの後ろは +02 など符号と2桁以上の数字となるため必ず3以上
				assert(valStrs.length == 2 && valStrs[1].length > 2);
				formattedWrite(dst, "%se%c%s",
					valStrs[0].stripRight("0"),         // 仮数部: 末尾の0をトリミングする
					valStrs[1][0],                      // 符号
					valStrs[1][1..$].stripLeft("0"));   // 指数部: 先頭の0をトリミングする
			}
			else
			{
				auto fmt = sformat(buf[], fpVal.positiveSign ? "%%+%de" : "%%%de", fpVal.precision);
				auto valStrs = sformat(buf[], fpVal.positiveSign ? "%+e" : "%e", fpVal.value).split("e");
				assert(valStrs.length == 2 && valStrs[1].length > 2);
				formattedWrite(dst, "%se%c%s",
					valStrs[0],                         // 仮数部: 末尾の0はトリミングしない
					valStrs[1][0],                      // 符号
					valStrs[1][1..$].stripLeft("0"));   // 指数部: 先頭の0をトリミングする
			}
		}
		else
		{
			if (fpVal.precision == 0)
			{
				auto valStr = sformat(buf[], fpVal.positiveSign ? "%+f" : "%f", fpVal.value).stripRight("0");
				if (fpVal.leadingDecimalPoint && valStr.startsWith("0."))
					put(dst, valStr[1 .. $]);
				else
					put(dst, valStr);
				if (fpVal.tailingDecimalPoint && !valStr.canFind('.'))
					put(dst, ".");
				if (!fpVal.tailingDecimalPoint && valStr[$-1] == '.')
					put(dst, "0");
			}
			else
			{
				auto fmt = fpVal.positiveSign ? sformat(buf[], "%%+.%df", fpVal.precision)
					: sformat(buf[], "%%.%df", fpVal.precision);
				auto valStr = sformat(buf[], fmt, fpVal.value);
				if (fpVal.leadingDecimalPoint && valStr.startsWith("0."))
					put(dst, valStr[1 .. $]);
				else
					put(dst, valStr);
				if (fpVal.tailingDecimalPoint && !valStr.canFind('.'))
					put(dst, ".");
			}
		}
	}
	
	private void _putPrettyStringJsonObjectImpl(OutputRange)(ref OutputRange dst, ref const(JsonValue.JsonObject) obj,
		in char[] indent, in char[] newline, size_t indentLevel,
		JsonPrettyPrintOptions options) const
	{
		if (obj.value.empty)
		{
			put(dst, "{}");
			return;
		}
		put(dst, "{");
		if (obj.singleLine)
		{
			foreach (i, ref kv; obj.value.byKeyValue)
			{
				_putPrettyStringJsonCommentImpl(dst, kv.value._comments, " ", null, 1, options, true);
				if (kv.value.type == JsonType.undefined)
					continue;
				put(dst, " ");
				
				// Output key
				if (kv.key.quotedStyle == QuotedStyle.unquoted)
				{
					put(dst, cast(const(char)[])kv.key.value[]);
				}
				else
				{
					char quote = kv.key.quotedStyle == QuotedStyle.singleQuoted ? '\'' : '"';
					put(dst, quote);
					put(dst, cast(const(char)[])kv.key.value[]);
					put(dst, quote);
				}
				// Value
				put(dst, ": ");
				_putPrettyStringImpl(dst, kv.value, indent, newline, indentLevel + 1, options);
				_putPrettyStringJsonTrailingCommentImpl(dst, kv.value._comments, true);
				if (i + 1 < obj.value.length || obj.tailingComma)
					put(dst, ",");
				if (i + 1 == obj.value.length)
					put(dst, " ");
			}
		}
		else
		{
			put(dst, newline);
			foreach (i, ref kv; obj.value.byKeyValue)
			{
				_putPrettyStringJsonCommentImpl(dst, kv.value._comments,
					indent, newline, indentLevel + 1, options, false);
				if (kv.value.type == JsonType.undefined)
					continue;
				put(dst, indent.repeat(indentLevel + 1));
				
				// Output key
				if (kv.key.quotedStyle == QuotedStyle.unquoted)
				{
					put(dst, cast(const(char)[])kv.key.value[]);
				}
				else
				{
					char quote = kv.key.quotedStyle == QuotedStyle.singleQuoted ? '\'' : '"';
					put(dst, quote);
					put(dst, cast(const(char)[])kv.key.value[]);
					put(dst, quote);
				}
				// Value
				put(dst, ": ");
				_putPrettyStringImpl(dst, kv.value, indent, newline, indentLevel + 1, options);
				if (i + 1 < obj.value.length || obj.tailingComma)
					put(dst, ",");
				_putPrettyStringJsonTrailingCommentImpl(dst, kv.value._comments, false);
				put(dst, newline);
			}
			put(dst, indent.repeat(indentLevel));
		}
		put(dst, "}");
	}
	
	private void _putPrettyStringJsonArrayImpl(OutputRange)(ref OutputRange dst, ref const(JsonValue.JsonArray) ary,
		in char[] indent, in char[] newline, size_t indentLevel,
		JsonPrettyPrintOptions options) const
	{
		if (ary.value.length == 0)
		{
			put(dst, "[]");
			return;
		}
		put(dst, "[");
		if (ary.singleLine)
		{
			foreach (i, ref v; ary.value)
			{
				put(dst, " ");
				_putPrettyStringImpl(dst, v, indent, newline, indentLevel + 1, options);
				_putPrettyStringJsonTrailingCommentImpl(dst, v._comments, true);
				if (i + 1 != ary.value.length || ary.tailingComma)
					put(dst, ",");
				if (i + 1 == ary.value.length)
					put(dst, " ");
			}
		}
		else
		{
			put(dst, newline);
			foreach (i, ref v; ary.value)
			{
				put(dst, indent.repeat(indentLevel + 1));
				_putPrettyStringJsonCommentImpl(dst, v._comments, indent, newline, indentLevel + 1, options);
				_putPrettyStringImpl(dst, v, indent, newline, indentLevel + 1, options);
				_putPrettyStringJsonTrailingCommentImpl(dst, v._comments, false);
				if (i + 1 != ary.value.length || ary.tailingComma)
					put(dst, ",");
				put(dst, newline);
			}
			put(dst, indent.repeat(indentLevel));
		}
		put(dst, "]");
	}
	
	private void _putPrettyStringImpl(OutputRange)(ref OutputRange dst, ref const(JsonValue) value,
		in char[] indent, in char[] newline, size_t indentLevel,
		JsonPrettyPrintOptions options) const
	{
		final switch (value.type)
		{
		case JsonType.undefined:
			// ignore
			break;
		case JsonType.string:
			_putPrettyStringJsonStringImpl(dst, value.asString, options);
			break;
		case JsonType.integer:
			_putPrettyStringJsonIntegerImpl(dst, value.asInteger);
			break;
		case JsonType.uinteger:
			_putPrettyStringJsonUIntegerImpl(dst, value.asUInteger);
			break;
		case JsonType.floating:
			_putPrettyStringJsonFloatingPointImpl(dst, value.asFloatingPoint);
			break;
		case JsonType.boolean:
			put(dst, value.get!bool ? "true" : "false");
			break;
		case JsonType.nullfied:
			put(dst, "null");
			break;
		case JsonType.array:
			_putPrettyStringJsonArrayImpl(dst, value.asArray, indent, newline, indentLevel, options);
			break;
		case JsonType.object:
			_putPrettyStringJsonObjectImpl(dst, value.asObject, indent, newline, indentLevel, options);
			break;
		}
	}
	
	/***************************************************************************
	 * Convert JSON value to pretty-printed string
	 */
	void toPrettyString(OutputRange)(ref OutputRange dst, JsonValue value,
		in char[] indent = "\t", in char[] newline = "\n",
		JsonPrettyPrintOptions options = JsonPrettyPrintOptions.none)
	{
		_putPrettyStringJsonCommentImpl(dst, value._comments, indent, newline, 0, options);
		_putPrettyStringImpl(dst, value, indent, newline, 0, options);
		_putPrettyStringJsonTrailingCommentImpl(dst, value._comments, false);
	}
	
	//##########################################################################
	//##### MARK: - - Update
	//##########################################################################
	
	private void _updateValue(T)(ref JsonValue dst, auto ref T src) const @safe
	{
		alias US = Unqual!T;
		static if (is(US == JsonValue))
			srcVal.match!((s) => _updateValue(dst, s));
		else static if (is(US == String))
		{
			dst._instance.match!(
				(ref JsonString v) {v.value = srcVal;},
				(_) @trusted { dst._instance = JsonString(srcVal, this); });
		}
		else static if (isInteger!US)
		{
			dst._instance.match!(
				(ref JsonInteger v) {v.value = srcVal;},
				(_) @trusted { dst._instance = JsonInteger(srcVal, this); });
		}
		else static if (isUInteger!US)
		{
			dst._instance.match!(
				(ref JsonUInteger v) {v.value = srcVal;},
				(_) @trusted { dst._instance = JsonUInteger(srcVal, this); });
		}
		else static if (isFloatingPoint!US)
		{
			dst._instance.match!(
				(ref JsonFloatingPoint v) { v.value = srcVal; },
				(_) @trusted { dst._instance = JsonFloatingPoint(srcVal, this); });
		}
		else static if (isBoolean!US)
		{
			dst._instance = srcVal;
		}
		else static if (is(US == typeof(null)))
		{
			dst._instance = null;
		}
		else static if (is(US == UndefinedValue))
		{
			dst._instance = UndefinedValue.init;
		}
		else static if (isBoolean!US)
		{
			dst._instance.match!(
				(ref bool v) { v = srcVal; },
				(_) @trusted { dst._instance = srcVal; });
		}
		else static if (isArray!US || is(US == Array!JsonValue))
		{
			dst._instance.match!(
				(ref JsonArray a) {
					a.value.length = srcVal.length;
					foreach (i, ref e; srcVal[])
						updateValue(a.value[i], e);
				},
				(_) {
					auto tmp = allocAry!JsonValue;
					foreach (i, ref e; srcVal[])
						tmp ~= serialize(e);
					dst._instance = JsonArray(tmp);
				});
		}
		else static if (isAssociativeArray!US || is(US == Dictionary!(JsonKey, JsonValue)))
		{
			dst._instance.match!(
				(ref JsonObject d) {
					auto tmp = allocDic!(JsonKey, JsonValue);
					foreach (ref itm; srcVal.byKeyValue)
					{
						if (auto pv = itm.key in d.value)
						{
							_updateValue(*pv, itm.value);
							tmp.append(JsonKey(itm.key), *pv);
						}
						else
							tmp.append(JsonKey(itm.key), serialize(itm.value));
					}
					dst._instance.value = tmp;
				},
				(_) {
					auto tmp = allocDic!(JsonKey, JsonValue);
					foreach (ref itm; srcVal.byKeyValue)
						tmp.append(JsonKey(itm.key), serialize(itm.value));
					dstVal._instance = JsonObject(tmp);
				});
		}
		else static if (is(US == JsonObject))
			_updateValue(dst, src.value);
		else static if (is(US == JsonArray))
			_updateValue(dst, src.value);
		else
		{
			dstVal._instance.match!(
				(ref US d) { d.value = srcVal.value; },
				(_) { dstVal._instance = srcVal; });
		}
	}
	
	/***************************************************************************
	 * Updates a JsonValue with struct data, preserving formatting as much as possible.
	 * 
	 * この関数はsrcの構造体データの値を使用して、dstのJsonValueの値部分のみを更新する目的で使用されます。
	 * dstは必ずオブジェクトである必要があります。さもなくば、emptyObjectで上書きされます。
	 * キーが存在しない場合は作成されます。
	 * 値の型が異なる場合は再作成されます。
	 */
	void update(T)(ref JsonValue dst, in T src) const @safe
	{
		import std.base64;
		alias U = Unqual!T;
		static if (is(U == JsonValue))
			_updateValue(dst, src);
		else static if (is(U == StdJsonValue))
			_updateValue(dst, JsonValue(value, this));
		else static if (isIntegral!T)
			_updateValue(dst, value);
		else static if (isFloatingPoint!T)
			_updateValue(dst, value);
		else static if (isBoolean!T)
			_updateValue(dst, value);
		else static if (isBinary!T)
			_updateValue(dst, Base64URLNoPadding.encode(value));
		else static if (is(T == typeof(null)))
			_updateValue(dst, value);
		else static if (isArray!T)
			_updateValue(dst, value);
		else static if (isAssociativeArray!T)
			_updateValue(dst, value);
		else static if (isTuple!T)
		{
			auto ary = allocAry!JsonValue();
			static foreach (idx; 0..value[].length)
				ary ~= serialize(value[idx]);
			_updateValue(dst, ary);
		}
		else static if (isSumType!T)
		{
			// SumTypeの場合
			// AggregateTypeの場合は、@kind属性で指定された値を付与して判別に用いる
			// それ以外の場合は、整数、実数、文字列、バイナリ、真偽値のいずれかがユニークでなければならない
			_updateValue(dst, value.match!(
				(ref e)
				{
					static if (isAggregateType!(typeof(e)) && hasKind!(typeof(e)))
					{
						alias Obj = Dictionary!(JsonKey, JsonValue);
						auto obj = serialize(e);
						enum kind = getKind!(typeof(e));
						obj._reqObj.prepend(Obj.Item(JsonKey(kind.key, this), JsonValue(kind.value, this)));
						return obj;
					}
					else
					{
						return serialize(e);
					}
				}
			));
		}
		else static if (isAggregateType!T && hasConvertJsonMethodA!T)
			_updateValue(dst, value.toJson(this));
		else static if (isAggregateType!T && hasConvertJsonMethodB!T)
			_updateValue(dst, deepCopy(value.toJson()));
		else static if (isAggregateType!T && hasConvertJsonMethodC!T)
			_updateValue(dst, JsonValue(value.toJson(), this));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodA!T)
			_updateValue(dst, Base64URLNoPadding.encode(value.toBinary()));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodB!T)
			_updateValue(dst, Base64URLNoPadding.encode(value.toRepresentation()));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodC!T)
			_updateValue(dst, value.toRepresentation());
		else static if (isAggregateType!T)
		{
			auto obj = allocDic!(JsonKey, JsonValue)();
			alias JsonValue = JV;
			alias JsonKey = JK;
			static foreach (i, e; value.tupleof[])
			{
				// メンバー変数をシリアライズ
				// @ignore属性が付与されている場合はシリアライズしない
				// @ignoreIf属性が付与されている場合はその条件に合致する場合はシリアライズしない
				// @name属性が付与されている場合はその名前を使用する
				// @value属性が付与されている場合はその値を使用する
				// @converter属性が付与されている場合はその関数による変換値を使用する
				static if (isAccessible!e && !hasIgnore!e)
				{{
					alias appendObj = ()
					{
						static if (hasName!e)
							alias getname = () => JK(getName!e, this);
						else
							alias getname = () => JK(e.stringof, this);
						static if (hasConvBy!e && canConvTo!(e, string))
							alias getval = () @trusted => JV(convTo!(e, string)(value.tupleof[i]), this);
						else static if (hasConvBy!e && canConvTo!(e, immutable(ubyte)[]))
							alias getval = () @trusted => JV(convTo!(e, immutable(ubyte)[])(value.tupleof[i]), this);
						else static if (hasConvBy!e && canConvTo!(e, JsonValue))
						{
							alias getval = () @trusted {
								auto v = undefinedValue;
								convertTo!e(value.tupleof[i], v);
								return v;
							};
						}
						else static if (hasConvBy!e && canConvTo!(e, StdJsonValue))
						{
							alias getval = () @trusted {
								auto v = StdJsonValue.init;
								convertTo!e(value.tupleof[i], v);
								return () @trusted => JV(v, this);
							};
						}
						else static if (hasValue!e)
							alias getval = () => serialzie(getValue!e);
						else
							alias getval = () => serialize(value.tupleof[i]);
						obj.append(getname(), getval());
					};
					static if (hasIgnoreIf!e)
					{
						if (!getPredIgnoreIf!e(value.tupleof[i]))
							appendObj();
					}
					else
					{
						appendObj();
					}
				}}
			}
			_updateValue(dst, obj);
		}
		else
		{
			return undefinedValue();
		}
	}
	
	//##########################################################################
	//##### MARK: - - Serializer
	//##########################################################################
	
	/***************************************************************************
	 * Serialize a various data to JsonValue
	 * 
	 * The serialize function generates a JsonValue instance from the given data.
	 * The data type must be one of the following.
	 * 
	 * - JsonValue
	 * - Integral type (int, uint, long, ulong, short, ushort, byte, ubyte)
	 * - Floating point type (float, double)
	 * - bool
	 * - string
	 * - binary (immutable(ubyte)[])
	 * - null
	 * - Array
	 *   - Recursively serialized
	 * - AssociativeArray
	 *   - Key allows string only
	 *   - Recursively serialized
	 * - Tuple
	 *   - Converted to a array type JsonValue
	 *   - Recursively serialized
	 * - SumType
	 *   - Converted to a object type JsonValue
	 *     - All types have the @kind attribute
	 *   - Recursively serialized
	 * - Aggregate type (struct, class, union): meets one of the following conditions
	 *   - Composed of simple public member variables
	 *     - Converted to a object type JsonValue
	 *     - Recursively serialized
	 *     - If the @ignore attribute is present, do not serialize
	 *     - If the @ignoreIf attribute is present, do not serialize if the condition is met
	 *     - If the @name attribute is present, use that name
	 *     - If the @converter attribute is present, use that conversion proxy
	 *     - If output formatting attributes are present, they will be used to decorate the output.
	 *       - The @stringFormat attribute modifies string output.
	 *       - The @integralFormat attribute modifies integral output.
	 *       - The @floatingPointFormat attribute modifies floating-point output.
	 *       - The @arrayFormat attribute modifies array output.
	 *       - The @objectFormat attribute modifies object output.
	 *       - The @quotedKeyStyle attribute modifies object key output.
	 *   - toJson/fromJson methods, where fromJson is a static method
	 *   - toString/fromString methods, where fromString is a static method
	 */
	JsonValue serialize(T)(in T src) @safe
	{
		import std.base64;
		alias U = Unqual!T;
		static if (is(U == JsonValue))
			return deepCopy(src);
		else static if (is(U == StdJsonValue))
			return make(src);
		else static if (isIntegral!T)
			return make(src);
		else static if (isFloatingPoint!T)
			return make(src);
		else static if (isBoolean!T)
			return make(src);
		else static if (isBinary!T)
			return make(Base64URLNoPadding.encode(src));
		else static if (is(T == typeof(null)))
			return make(src);
		else static if (isArray!T)
			return make(src);
		else static if (isAssociativeArray!T)
			return make(src);
		else static if (isTuple!T)
		{
			auto ary = allocAry!JsonValue();
			static foreach (idx; 0..src[].length)
				ary ~= serialize(src[idx]);
			return make(ary);
		}
		else static if (isSumType!T)
		{
			// SumTypeの場合
			// AggregateTypeの場合は、@kind属性で指定された値を付与して判別に用いる
			// それ以外の場合は、整数、実数、文字列、バイナリ、真偽値のいずれかがユニークでなければならない
			return src.match!(
				(ref e) @trusted
				{
					static if (isAggregateType!(typeof(e)) && hasKind!(typeof(e)))
					{
						alias Obj = Dictionary!(JsonKey, JsonValue);
						auto obj = serialize(e);
						enum kind = getKind!(typeof(e));
						obj._reqObj.prepend(JsonKey(allocStr(kind.key)), make(kind.value));
						return obj;
					}
					else
					{
						return serialize(e);
					}
				}
			);
		}
		else static if (isAggregateType!T && hasConvertJsonMethodA!T)
			return src.toJson(this);
		else static if (isAggregateType!T && hasConvertJsonMethodB!T)
			return make(src.toJson());
		else static if (isAggregateType!T && hasConvertJsonMethodC!T)
			return make(src.toJson());
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodA!T)
			return make(Base64URLNoPadding.encode(src.toBinary()));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodB!T)
			return make(Base64URLNoPadding.encode(src.toRepresentation()));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodC!T)
			return make(src.toRepresentation());
		else static if (isAggregateType!T)
		{
			auto obj = allocDic!(JsonKey, JsonValue)();
			static foreach (i, e; src.tupleof[])
			{
				// メンバー変数をシリアライズ
				// @ignore属性が付与されている場合はシリアライズしない
				// @ignoreIf属性が付与されている場合はその条件に合致する場合はシリアライズしない
				// @name属性が付与されている場合はその名前を使用する
				// @value属性が付与されている場合はその値を使用する
				// @converter属性が付与されている場合はその関数による変換値を使用する
				static if (isAccessible!e && !hasIgnore!e)
				{{
					alias E = typeof(e);
					alias appendObj = ()
					{
						static if (hasName!e)
							alias getname = () => JsonKey(allocStr(getName!e));
						else
							alias getname = () => JsonKey(allocStr(e.stringof));
						static if (hasConvBy!e && canConvTo!(e, string))
							alias getval = () => make(convTo!(e, string)(src.tupleof[i]));
						else static if (hasConvBy!e && canConvTo!(e, immutable(ubyte)[]))
							alias getval = () => serialize(convTo!(e, immutable(ubyte)[])(src.tupleof[i]));
						else static if (hasConvBy!e && canConvTo!(e, JsonValue))
						{
							alias getval = () {
								auto v = undefinedValue;
								convertTo!e(src.tupleof[i], v);
								return v;
							};
						}
						else static if (hasConvBy!e && canConvTo!(e, StdJsonValue))
						{
							alias getval = () {
								auto v = StdJsonValue.init;
								convertTo!e(src.tupleof[i], v);
								return make(v);
							};
						}
						else
							alias getval = () => serialize(src.tupleof[i]);
						auto key = getname();
						auto val = getval();
						// コメント
						static foreach (c; getAttrJson5Comments!e)
							val.addComment(c.value, c.type);
						// キー
						static if (hasAttrJson5KeyQuotedStyle!e)
							key.quotedStyle = getAttrJson5KeyQuotedStyle!e.style;
						else static if (hasAttrJson5KeyQuotedStyle!T)
							key.quotedStyle = getAttrJson5KeyQuotedStyle!T.style;
						// 各型の修飾
						static if (isSomeString!E && hasAttrJson5StringFormat!e)
						{
							assert(val.type == JsonType.string);
							val.asString.singleQuoted = getAttrJson5StringFormat!e.singleQuoted;
						}
						else static if (isIntegral!E && isSigned!E && hasAttrJson5IntegralFormat!e)
						{
							assert(val.type == JsonType.integer);
							val.asInteger.positiveSign = getAttrJson5IntegralFormat!e.positiveSign;
							val.asInteger.hex          = getAttrJson5IntegralFormat!e.hex;
						}
						else static if (isIntegral!E && isUnsigned!E && hasAttrJson5IntegralFormat!e)
						{
							assert(val.type == JsonType.uinteger);
							val.asUInteger.positiveSign = getAttrJson5IntegralFormat!e.positiveSign;
							val.asUInteger.hex          = getAttrJson5IntegralFormat!e.hex;
						}
						else static if (isFloatingPoint!E && hasAttrJson5FloatingPointFormat!e)
						{
							assert(val.type == JsonType.floating);
							val.asFloatingPoint.leadingDecimalPoint = getAttrJson5FloatingPointFormat!e.leadingDecimalPoint;
							val.asFloatingPoint.tailingDecimalPoint = getAttrJson5FloatingPointFormat!e.tailingDecimalPoint;
							val.asFloatingPoint.positiveSign        = getAttrJson5FloatingPointFormat!e.positiveSign;
							val.asFloatingPoint.withExponent        = getAttrJson5FloatingPointFormat!e.withExponent;
							val.asFloatingPoint.precision           = getAttrJson5FloatingPointFormat!e.precision;
						}
						else static if (isArray!E && hasAttrJson5ArrayFormat!e)
						{
							assert(val.type == JsonType.array);
							val.asArray.tailingComma = getAttrJson5ArrayFormat!e.tailingComma;
							val.asArray.singleLine   = getAttrJson5ArrayFormat!e.singleLine;
						}
						else static if (isAggregateType!E && hasAttrJson5ObjectFormat!e)
						{
							assert(val.type == JsonType.object);
							val.asObject.tailingComma = getAttrJson5ObjectFormat!e.tailingComma;
							val.asObject.singleLine   = getAttrJson5ObjectFormat!e.singleLine;
						}
						else
						{
							// 何もしない
						}
						obj.append(key, val);
					};
					static if (hasIgnoreIf!e)
					{
						if (!getPredIgnoreIf!e(value.tupleof[i]))
							appendObj();
					}
					else static if (isPointer!(typeof(e)) && e.stringof == "this")
					{
						// Workaround of closure
						if (false)
							appendObj();
					}
					else
					{
						appendObj();
					}
				}}
			}
			static if (hasAttrJson5ObjectFormat!T)
			{
				return make(JsonObject(obj,
					getAttrJson5ObjectFormat!T.tailingComma,
					getAttrJson5ObjectFormat!T.singleLine));
			}
			else
			{
				return make(JsonObject(obj));
			}
		}
		else
		{
			return undefinedValue();
		}
	}
	
	
	//##########################################################################
	//##### MARK: - - Deserializer
	//##########################################################################
	
	/***************************************************************************
	 * Deserialize JSON value to specified structure
	 * 
	 * The deserialize function generates value from JsonValue instance.
	 * The data type must be one of the following.
	 * 
	 * - JsonValue
	 * - Integral type (int, uint, long, ulong, short, ushort, byte, ubyte)
	 * - Floating point type (float, double)
	 * - bool
	 * - string
	 * - binary (immutable(ubyte)[])
	 * - null
	 * - Array
	 *   - Recursively deserialized
	 * - AssociativeArray
	 *   - Recursively deserialized
	 * - SumType
	 *   - Converted from a map type JsonValue
	 *     - All types have the @kind attribute
	 *   - Recursively deserialized
	 * - Aggregate type (struct, class, union): meets one of the following conditions
	 *   - Composed of simple public member variables
	 *     - Converted to a map type JsonValue
	 *     - Recursively deserialized
	 *     - If the @ignore attribute is present, do not deserialize
	 *     - If the @ignoreIf attribute is present, do not deserialize if the condition is met
	 *     - If the @name attribute is present, use that name
	 *     - If the @converter attribute is present, use that conversion proxy
	 *     - If the @essential attribute is present, throw an exception if deserialization fails
	 *   - toJson/fromJson methods, where fromJson is a static method
	 *   - toBinary/fromBinary methods, where fromBinary is a static method
	 *   - toRepresentation/fromRepresentation methods, where fromRepresentation is a static method
	 */
	void deserializeImpl(T)(in JsonValue src, ref T dst) @safe
	{
		import std.base64;
		alias U = Unqual!T;
		static if (is(U == JsonValue))
			dst = deepCopy(src);
		else static if (is(U == StdJsonValue))
			dst = src.toStdJson();
		else static if (isIntegral!T)
			dst = src.get!U;
		else static if (isFloatingPoint!T)
			dst = src.get!U;
		else static if (isBoolean!T)
			dst = src.get!U;
		else static if (isBinary!T)
			dst = Base64URLNoPadding.decode(src.get!string);
		else static if (is(T == typeof(null)))
			dst = null;
		else static if (isArray!T)
		{
			// 配列
			dst.length = src._reqArray.length;
			foreach (i, ref e; src._reqArray)
				deserializeImpl(e, dst[i]);
		}
		else static if (isAssociativeArray!T)
		{
			// 連想配列
			foreach (ref e; src._reqObj.byKeyValue)
			{
				ValueType!T value;
				deserializeImpl(e.value, value);
				dst[e.key.value[]] = value;
			}
		}
		else static if (isTuple!T)
		{
			auto ary = src._reqArray;
			static foreach (idx; 0..dst.length)
				deserialize(ary[idx], dst[idx]);
		}
		else static if (isSumType!T)
		{
			// SumTypeの場合
			// AggregateTypeの場合は、@kind属性で指定された値を付与して判別に用いる
			// それ以外の場合は、整数、実数、文字列、バイナリ、真偽値のいずれかがユニークでなければならない
			switch (src.type)
			{
			case JsonType.integer:
			case JsonType.uinteger:
				alias Types = Filter!(isIntegral, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case JsonType.floating:
				alias Types = Filter!(isFloatingPoint, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case JsonType.string:
				alias Types1 = Filter!(isSomeString, T.Types);
				alias Types2 = Filter!(isBinary, T.Types);
				static if (Types1.length == 1 && Types2.length == 0)
				{
					Types1[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				else static if (Types1.length == 0 && Types2.length == 1)
				{
					Types2[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				else
				{
					// Ignore
				}
				break;
			case JsonType.nullfied:
				import std.typecons: Nullable, NullableRef;
				enum isNullable(X) = is(X == typeof(null)) || isInstanceOf!(Nullable, X) || isInstanceOf!(NullableRef, X);
				alias Types = Filter!(isNullable, T.Types);
				static if (Types.length == 1)
				{
					static if (is(Types[0] == typeof(null)))
						dst = null;
					else
						dst.nullify();
				}
				break;
			case JsonType.undefined:
				// Ignore
				break;
			case JsonType.boolean:
				alias Types = Filter!(isBoolean, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case JsonType.array:
				alias Types = Filter!(isArrayWithoutBinary, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case JsonType.object:
				immutable kinds = [staticMap!(getKind, Filter!(isAggregateType, T.Types))];
				size_t kindIdx = -1;
				static if (kinds.length)
				{
					foreach (i, ref e; src._reqObj.byKeyValue)
					{
						foreach (kind; kinds)
						{
							if (e.key.value[] == kind.key && e.value._reqStr[] == kind.value)
							{
								kindIdx = i;
								break;
							}
						}
						if (kindIdx != -1)
							break;
					}
				}
				if (kindIdx != -1)
				{
					// isAggregateType
					alias Types = Filter!(isAggregateType, T.Types);
					static foreach (i, E; Types)
					{
						if (kindIdx == i)
						{
							E ret;
							deserializeImpl(src, ret);
							(() @trusted => dst = ret.move)();
						}
					}
				}
				else
				{
					// isAssociativeArray
					alias Types = Filter!(isAssociativeArray, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						deserializeImpl(src, ret);
						(() @trusted => dst = ret.move)();
					}
				}
				break;
			default:
				// Ignore
				break;
			}
		}
		else static if (isAggregateType!T && hasConvertJsonMethodA!T)
			dst = T.fromJson(src);
		else static if (isAggregateType!T && hasConvertJsonMethodB!T)
			dst = T.fromJson(src);
		else static if (isAggregateType!T && hasConvertJsonMethodC!T)
			dst = T.fromJson(src.toStdJson());
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodA!T)
			dst = T.fromBinary(Base64URLNoPadding.decode(src.get!string));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodB!T)
			dst = T.fromRepresentation(Base64URLNoPadding.decode(src.get!string));
		else static if (isAggregateType!T && hasConvertJsonBinaryMethodC!T)
			dst = T.fromRepresentation(src.get!string);
		else static if (isAggregateType!T)
		{
			// その他の構造体・クラス
			static foreach (i, m; dst.tupleof[])
			{{
				// メンバー変数をデシリアライズ
				// @ignore属性が付与されている場合はデシリアライズしない
				// @ignoreIf属性が付与されている場合はその条件に合致する場合はシリアライズしない
				// @name属性が付与されている場合はその名前を使用する
				// @converter属性が付与されている場合はその関数による変換値を使用する
				// @essential属性が付与されている場合は変換できない場合に例外を投げる
				static if (hasEssential!m)
					bool found = false;
				static if (isAccessible!m && !hasIgnore!m)
				{
					static if (hasIgnoreIf!m)
						bool isIgnored = getPredIgnoreIf!m(value.tupleof[i]);
					else
						enum isIgnored = false;
					if (!isIgnored) foreach (ref e; src._reqObj.byKeyValue)
					{
						static if (hasName!m)
							enum memberName = getName!m;
						else
							enum memberName = m.stringof;
						
						if (e.key.value == memberName)
						{
							static if (hasConvBy!m && canConvFrom!(m, string))
								dst.tupleof[i] = (() @trusted => convFrom!(m, string)(e.value.get!string))();
							else static if (hasConvBy!m && canConvFrom!(m, immutable(ubyte)[]))
							{
								immutable(ubyte)[] tmp;
								deserializeImpl(e.value, tmp);
								dst.tupleof[i] = (() @trusted => convFrom!(m, immutable(ubyte)[])(tmp))();
							}
							else static if (hasConvBy!m && canConvFrom!(m, JsonValue))
								dst.tupleof[i] = convFrom!(m, JsonValue)(e.value);
							else static if (hasConvBy!m && canConvFrom!(m, StdJsonValue))
								dst.tupleof[i] = convFrom!(m, StdJsonValue)(e.value.toStdJson());
							else
								deserializeImpl(e.value, dst.tupleof[i]);
							static if (hasEssential!m)
								found = true;
							break;
						}
					}
				}
				static if (hasEssential!m)
					enforce(found, "Essential member[" ~ m.stringof ~ "] is not found.");
			}}
		}
		else
		{
			// ignore
		}
	}
	/// ditto
	bool deserialize(T)(in JsonValue src, ref T dst) @safe
	{
		return !deserializeImpl(src, dst).collectException;
	}
	/// ditto
	T deserialize(T)(in JsonValue src) @safe
	{
		T dst;
		deserializeImpl(src, dst);
		return dst;
	}
}

//######################################################################
//##### MARK: - Export Types
//######################################################################

alias Json5Builder       = Json5BuilderImpl!Json5DefaultAllocator;
///
alias Json5Value         = Json5Builder.JsonValue;
///
alias Json5Type          = Json5Builder.JsonType;
///
alias Json5String        = Json5Builder.JsonValue.JsonString;
///
alias Json5UInteger      = Json5Builder.JsonValue.JsonUInteger;
///
alias Json5Integer       = Json5Builder.JsonValue.JsonInteger;
///
alias Json5FloatingPoint = Json5Builder.JsonValue.JsonFloatingPoint;
///
alias Json5Object        = Json5Builder.JsonValue.JsonObject;
///
alias Json5Array         = Json5Builder.JsonValue.JsonArray;
///
alias Json5Options       = Json5Builder.JsonPrettyPrintOptions;

private __gshared Json5Builder g_defaultBuilder;

///
Json5Value makeJson(T)(in T val) @safe
{
	return g_defaultBuilder.make(val);
}
///
Json5Value parseJson(in char[] str) @safe
{
	return g_defaultBuilder.parse(str);
}
///
Json5Value serializeToJson(T)(in T src) @safe
{
	return g_defaultBuilder.serialize(src);
}
///
string serializeToJsonString(T)(in T src, in char[] indent = "\t", in char[] newline = "\n",
		Json5Options options = Json5Options.none) @safe
{
	return g_defaultBuilder.serialize(src).toPrettyString(indent, newline, options);
}
///
bool deserializeFromJson(T)(in Json5Value src, ref T dst) @safe
{
	return g_defaultBuilder.deserialize(src, dst);
}
/// ditto
T deserializeFromJson(T)(in Json5Value src) @safe
{
	return g_defaultBuilder.deserialize!T(src);
}
/// ditto
bool deserializeFromJsonString(T)(in char[] src, ref T dst) @safe
{
	return deserializeFromJson(g_defaultBuilder.parse(src, dst));
}
/// ditto
T deserializeFromJsonString(T)(in Json5Value src) @safe
{
	return deserializeFromJson!T(g_defaultBuilder.parse(src));
}

//######################################################################
//##### MARK: - Unittests
//######################################################################
///
@system unittest
{
	import std.math: isClose;
	Json5Builder builder;
	// 文字列
	auto jv = builder.make("test");
	assert(jv.get!string == "test");
	assert(jv.get!uint == 0);
	assert(jv.get!bool);
	assert(jv.get!(typeof(null)) is null);
	assert(jv.get!(string[string]) is null);
	// 符号あり数値
	jv = builder.make(10);
	assert(jv.get!int == 10);
	assert(jv.get!uint == 10);
	assert(jv.get!float.isClose(10));
	assert(jv.get!string == "");
	assert(jv.get!bool);
	assert(jv.get!(typeof(null)) is null);
	assert(jv.get!(string[string]) is null);
	// 符号なし整数
	jv = builder.make(11U);
	assert(jv.get!int == 11);
	assert(jv.get!uint == 11);
	assert(jv.get!float.isClose(11));
	assert(jv.get!string == "");
	assert(jv.get!bool);
	assert(jv.get!(typeof(null)) is null);
	assert(jv.get!(string[string]) is null);
	// 浮動小数点数
	jv = builder.make(12.3);
	assert(jv.get!float.isClose(12.3));
	assert(jv.get!int == 12);
	assert(jv.get!uint == 12);
	assert(jv.get!string == "");
	assert(jv.get!(typeof(null)) is null);
	assert(jv.get!(string[string]) is null);
	// 論理値
	jv = builder.make(true);
	assert(jv.get!bool);
	jv = builder.make(false);
	assert(!jv.get!bool);
	// NULL
	jv = builder.make(null);
	assert(jv.get!(typeof(null)) is null);
	// 配列
	jv = builder.make(["test1", "test2"]);
	assert(jv.get!(string[]).length == 2);
	assert(jv.get!(string[]) == ["test1", "test2"]);
	// 連想配列
	jv = builder.make(["test": "value"]);
	assert(jv.get!(string[string])["test"] == "value");
	jv = builder.make(["test2": 42]);
	assert(jv.get!(int[string])["test2"] == 42);
	jv = builder.make(["test3": builder.make(true)]);
	assert(jv.get!(bool[string])["test3"] == true);
	
	jv = builder.make(cast(const string)"test");
	assert(jv.get!string == "test");
	
	jv = builder.make(cast(const ubyte[])"\x01\x02\x03");
	assert(jv.get!(ubyte[]) == [1, 2, 3]);
}

@system unittest
{
	import std.math: isClose;
	Json5Builder builder;
	Json5Value jv;
	
	// 数値
	jv = builder.parse("0x123F");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!uint == 0x123F);
	jv = builder.parse("0x8FFFFFFFFFFF123F");
	assert(jv.type == Json5Type.uinteger);
	assert(jv.get!ulong == 0x8FFFFFFFFFFF123FUL);
	
	jv = builder.parse("456");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 456);
	assert(!jv.asInteger.positiveSign);
	
	jv = builder.parse("+456");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 456);
	assert(jv.asInteger.positiveSign);
	
	jv = builder.parse("0.25");
	assert(jv.type == Json5Type.floating);
	assert(jv.get!double == 0.25);
	
	jv = builder.parse("0.25e-3");
	assert(jv.type == Json5Type.floating);
	assert(jv.get!double == 0.00025);
	
	jv = builder.parse("5e3");
	assert(jv.type == Json5Type.floating);
	assert(jv.get!double == 5000.0);
	
	// 文字列
	jv = builder.parse(`"aaaaa"`);
	assert(jv.type == Json5Type.string);
	assert(jv.get!string == "aaaaa");
	
	jv = builder.parse(`"aa\n\'a\"a\t\v\f\b\r\/\\a\u2000a\0a"`);
	assert(jv.type == Json5Type.string);
	assert(jv.get!string == "aa\n\'a\"a\t\v\f\b\r/\\a\u2000a\0a");
	
	jv = builder.parse("\"aa\naa\\\rabbb\\\r\nccc\\\nddd\rxeee\r\nfff\\k\"");
	assert(jv.type == Json5Type.string);
	assert(jv.get!string == "aa\naaabbbcccddd\nxeee\nfffk");
	
	jv = builder.parse(`'aaaaa'`);
	assert(jv.type == Json5Type.string);
	assert(jv.get!string == "aaaaa");
	
	jv = builder.parse(`'aa\n\'a\"a\t\v\f\b\r\/\\a\u2000a\0a'`);
	assert(jv.type == Json5Type.string);
	assert(jv.get!string == "aa\n\'a\"a\t\v\f\b\r/\\a\u2000a\0a");
	
	jv = builder.parse("\'aa\naa\\\rabbb\\\r\nccc\\\nddd\rxeee\r\nfff\\k\'");
	assert(jv.type == Json5Type.string);
	assert(jv.get!string == "aa\naaabbbcccddd\nxeee\nfffk");
	assert(!jv.hasTrailingComment);
	
	// ラインコメントのみ
	jv = builder.parse("// this is a line comment\n123");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 123);
	assert(jv.getCommentLength() == 1);
	assert(jv.isLineComment(0));
	assert(!jv.isTrailingComment(0));
	assert(!jv.isBlockComment(0));
	assert(jv.asLineComment(0).value[] == " this is a line comment");
	assert(jv.getComment(0) == "this is a line comment");
	
	// ブロックコメントのみ
	jv = builder.parse("/* block comment */456");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 456);
	assert(jv.getCommentLength() == 1);
	assert(!jv.isLineComment(0));
	assert(jv.isBlockComment(0));
	assert(jv.asBlockComment(0).value[0] == " block comment ");
	assert(jv.getComment(0) == "block comment");

	// 複数行ブロックコメント
	jv = builder.parse("/* line1\nline2\nline3 */789");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 789);
	assert(jv.getCommentLength() == 1);
	assert(!jv.isLineComment(0));
	assert(jv.isBlockComment(0));
	assert(jv.asBlockComment(0)[0] == " line1");
	assert(jv.asBlockComment(0)[1] == "line2");
	assert(jv.asBlockComment(0)[2] == "line3 ");
	assert(jv.getComment(0) == " line1\nline2\nline3");

	// ラインコメントとブロックコメントの混在
	jv = builder.parse("// comment1\n/* comment2 */100");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 100);
	assert(jv.getCommentLength() == 2);
	assert(jv.isLineComment(0));
	assert(!jv.isBlockComment(0));
	assert(!jv.isLineComment(1));
	assert(jv.isBlockComment(1));
	assert(jv.asLineComment(0).value[] == " comment1");
	assert(jv.asBlockComment(1).value[0][] == " comment2 ");
	assert(jv.getComments() == "comment1\ncomment2");
	
	// 末尾にコメント
	jv = builder.parse("200 // end comment");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 200);
	assert(jv.getCommentLength() == 1);
	assert(!jv.isLineComment(0));
	assert(!jv.isBlockComment(0));
	assert(jv.isTrailingComment(0));
	assert(jv.hasTrailingComment());
	assert(jv.asTrailingComment(0)[] == " end comment");
	assert(jv.getComment(0) == "end comment");
	
	// 空コメント
	jv = builder.parse("//\n/*\n*/300");
	assert(jv.type == Json5Type.integer);
	assert(jv.get!int == 300);
	assert(jv.getCommentLength() == 2);
	assert(jv.isLineComment(0));
	assert(!jv.isBlockComment(0));
	assert(!jv.isLineComment(1));
	assert(jv.isBlockComment(1));
	assert(jv.asLineComment(0)[] == "");
	assert(jv.asBlockComment(1).value.length == 2);
	assert(jv.asBlockComment(1)[0] == "");
	assert(jv.asBlockComment(1)[1] == "");
	assert(jv.getComment(1) == "");
	
	// オブジェクト
	jv = builder.parse(`{
		// This is a line comment
		'key1': "value1", // Tailing comment
		/* This is a block comment */
		key2: 123, // Another line comment
		"KEY3": 0x1A3F,
	}`);
	assert(jv.type == Json5Type.object);
	assert(jv.getValue!string("key1") == "value1");
	assert(jv.getValue!int("key2") == 123);
	assert(jv.getValue!ushort("KEY3") == 0x1A3F);
	assert(jv.asObject[0].value.asLineComment(0)[] == " This is a line comment");
	assert(jv.asObject[0].value.asTrailingComment(1) == " Tailing comment");
	assert(jv.asObject[1].value.asBlockComment(0)[0] == " This is a block comment ");
	assert(jv.asObject[1].value.asTrailingComment(1) == " Another line comment");
	assert(jv.asObject[2].value.getCommentLength() == 0);
	assert(jv.asObject.tailingComma);
	assert(!jv.asObject.singleLine);
	
	// オブジェクト シングルライン
	jv = builder.parse(`{ 'key1': "value1" /* COMMENT1 */, key2: 123, "KEY3": 0x1A3F /* COMMENT2 */, }`);
	assert(jv.type == Json5Type.object);
	assert(jv.getValue!string("key1") == "value1");
	assert(jv.getValue!int("key2") == 123);
	assert(jv.getValue!ushort("KEY3") == 0x1A3F);
	assert(jv.asObject[0].value.asTrailingComment(0)[] == " COMMENT1 ");
	assert(jv.asObject[2].value.asTrailingComment(0)[] == " COMMENT2 ");
	assert(jv.asObject.tailingComma);
	assert(jv.asObject.singleLine);
	
	
	// オブジェクト いろんなところにコメント
	jv = builder.parse(`{
		'key1':
			// This is a line comment
			/* This is a block comment */
			"value1",
		key2 /* TEST */ : /* Block comment */ 123 /* Another block comment */,
		
		"KEY3": 0x1A3F
			// TEST COMMENT
		}
	}`);
	assert(jv.type == Json5Type.object);
	assert(jv.getValue!string("key1") == "value1");
	assert(jv.getValue!int("key2") == 123);
	assert(jv.getValue!ushort("KEY3") == 0x1A3F);
	assert(jv.asObject[0].value.asLineComment(0)[] == " This is a line comment");
	assert(jv.asObject[0].value.asBlockComment(1)[0] == " This is a block comment ");
	assert(jv.asObject[1].value.asBlockComment(0)[0] == " TEST ");
	assert(jv.asObject[1].value.asBlockComment(1)[0] == " Block comment ");
	assert(jv.asObject[1].value.asTrailingComment(2) == " Another block comment ");
	assert(jv.asObject[2].value.getCommentLength() == 0);
	assert(!jv.asObject.tailingComma);
	
	// 配列のテスト
	jv = builder.parse("[1, 2, 3]");
	assert(jv.type == Json5Type.array);
	assert(jv.asArray.length == 3);
	assert(jv.getElement!int(0) == 1);
	assert(jv.getElement!int(1) == 2);
	assert(jv.getElement!int(2) == 3);
	assert(jv.asArray.tailingComma == false);
	
	jv = builder.parse("[1, 2, 3,]");
	assert(jv.type == Json5Type.array);
	assert(jv.asArray.length == 3);
	assert(jv.getElement!int(0) == 1);
	assert(jv.getElement!int(1) == 2);
	assert(jv.getElement!int(2) == 3);
	assert(jv.asArray.tailingComma == true);
	
	jv = builder.parse("[1, // comment1\n 2, /* comment2 */ 3, ]");
	assert(jv.type == Json5Type.array);
	assert(jv.asArray.length == 3);
	assert(jv.getElement!int(0) == 1);
	assert(jv.getElement!int(1) == 2);
	assert(jv.getElement!int(2) == 3);
	assert(jv.asArray.tailingComma);
	assert(jv.asArray[0].asTrailingComment(0)[] == " comment1");
	assert(jv.asArray[1].asTrailingComment(0)[] == " comment2 ");
	
	// ネストした配列
	jv = builder.parse("[1, [2, 3,], [4, [5]]]");
	assert(jv.type == Json5Type.array);
	assert(jv.getElement!int(0) == 1);
	assert(jv.asArray.singleLine);
	assert(jv.asArray[1].getElement!int(0) == 2);
	assert(jv.asArray[1].getElement!int(1) == 3);
	assert(jv.asArray[1].asArray.tailingComma);
	assert(jv.asArray[1].asArray.singleLine);
	assert(jv.asArray[2].getElement!int(0) == 4);
	assert(jv.asArray[2].asArray[1].getElement!int(0) == 5);
	
	// 複数行ネストした配列
	jv = builder.parse(`
		[
			1,
			[2, 3,],
			[
				4, [
					5
				]
			]
		]`.chompPrefix("\n").outdent);
	assert(jv.type == Json5Type.array);
	assert(jv.getElement!int(0) == 1);
	assert(!jv.asArray.singleLine);
	assert(jv.asArray[1].getElement!int(0) == 2);
	assert(jv.asArray[1].getElement!int(1) == 3);
	assert(jv.asArray[1].asArray.tailingComma);
	assert(jv.asArray[1].asArray.singleLine);
	assert(jv.asArray[2].getElement!int(0) == 4);
	assert(jv.asArray[2].asArray[1].getElement!int(0) == 5);
	
	// 空配列
	jv = builder.parse("[]");
	assert(jv.type == Json5Type.array);
	assert(jv.asArray.length == 0);
	assert(jv.asArray.tailingComma == false);
	
	// 配列内のコメント
	jv = builder.parse(`
	[
		// LINE COMMENT1
		"abcde",
		// LINE COMMENT2
		12345, // TRAILING COMMMENT2
		/* BLOCK COMMENT3 */
		false, /* TRAILING COMMMENT3 */
	]`.chompPrefix("\n").outdent);
	assert(jv.type == Json5Type.array);
	assert(jv.asArray.length == 3);
	assert(jv.asArray.tailingComma == true);
	assert(jv.asArray[0].asLineComment(0) == " LINE COMMENT1");
	assert(jv.asArray[1].asLineComment(0) == " LINE COMMENT2");
	assert(jv.asArray[1].asTrailingComment(1) == " TRAILING COMMMENT2");
	assert(jv.asArray[2].asBlockComment(0)[0] == " BLOCK COMMENT3 ");
	assert(jv.asArray[2].asTrailingComment(1) == " TRAILING COMMMENT3 ");
	
	// Example from spec.json5.org
	jv = builder.parse(`
		{
		  // comments
		  unquoted: 'and you can quote me on that',
		  singleQuotes: 'I can use "double quotes" here',
		  lineBreaks: "Look, Mom! \
		No \\n's!",
		  hexadecimal: 0xdecaf,
		  leadingDecimalPoint: .8675309, andTrailing: 8675309.,
		  positiveSign: +1,
		  trailingComma: 'in objects', andIn: ['arrays',],
		  "backwardsCompatible": "with JSON",
		}`.chompPrefix("\n").outdent);
	assert(jv.type == Json5Type.object);
	assert(jv.asObject[0].value.getCommentLength() == 1);
	assert(jv.asObject[0].value.getComment(0) == "comments");
	assert(jv.getValue!string("unquoted") == "and you can quote me on that");
	assert(jv.asObject[1].key.quotedStyle == QuotedStyle.unquoted);
	assert(jv.getValue!string("singleQuotes") == `I can use "double quotes" here`);
	assert(jv.getValue!Json5String("singleQuotes").singleQuoted);
	assert(jv.getValue!string("lineBreaks") == "Look, Mom! No \\n's!");
	assert(jv.getValue!uint("hexadecimal") == 0xdecaf);
	assert(jv.getValue!Json5Integer("hexadecimal").hex);
	assert(jv.getValue!real("leadingDecimalPoint").isClose(0.8675309));
	assert(jv.getValue!Json5FloatingPoint("leadingDecimalPoint").leadingDecimalPoint);
	assert(jv.getValue!Json5FloatingPoint("leadingDecimalPoint").precision == 7);
	assert(jv.getValue!real("andTrailing").isClose(8675309.0));
	assert(jv.getValue!Json5FloatingPoint("andTrailing").tailingDecimalPoint);
	assert(jv.getValue!Json5FloatingPoint("andTrailing").precision == 0);
	assert(jv.getValue!int("positiveSign") == 1);
	assert(jv.getValue!Json5Integer("positiveSign").positiveSign);
	assert(jv.getValue!string("trailingComma") == "in objects");
	assert(jv.asObject.tailingComma);
	assert(jv.getValue!Json5Array("andIn")[0].get!string == "arrays");
	assert(jv.getValue!Json5Array("andIn").tailingComma);
	assert(jv.getValue!string("backwardsCompatible") == "with JSON");
}

@system unittest
{
	Json5Builder builder;
	Json5Value jv;
	
	auto app = appender!(char[])();
	
	jv = builder.make(123);
	builder._putPrettyStringJsonIntegerImpl(app, jv.asInteger);
	assert(app.data == "123");
	app.shrinkTo(0);
	
	jv.asInteger.positiveSign = true;
	builder._putPrettyStringJsonIntegerImpl(app, jv.asInteger);
	assert(app.data == "+123");
	app.shrinkTo(0);
	
	jv.asInteger.hex = true;
	builder._putPrettyStringJsonIntegerImpl(app, jv.asInteger);
	assert(app.data == "+0x7B");
	app.shrinkTo(0);
	
	jv.asInteger.positiveSign = false;
	builder._putPrettyStringJsonIntegerImpl(app, jv.asInteger);
	assert(app.data == "0x7B");
	app.shrinkTo(0);
	
	jv.asInteger.positiveSign = false;
	jv.asInteger.value = -123;
	builder._putPrettyStringJsonIntegerImpl(app, jv.asInteger);
	assert(app.data == "-0x7B");
	app.shrinkTo(0);
	
	jv.asInteger.value = 0x123456789;
	builder._putPrettyStringJsonIntegerImpl(app, jv.asInteger);
	assert(app.data == "0x0000000123456789");
	app.shrinkTo(0);
	
	
	jv = builder.make(Json5UInteger(123));
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "123");
	app.shrinkTo(0);
	
	jv.asUInteger.positiveSign = true;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "+123");
	app.shrinkTo(0);
	
	jv.asUInteger.hex = true;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "+0x7B");
	app.shrinkTo(0);
	
	jv.asUInteger.positiveSign = false;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "0x7B");
	app.shrinkTo(0);
	
	jv.asUInteger.value = 0x123;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "0x0123");
	app.shrinkTo(0);
	
	jv.asUInteger.value = 0x1234;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "0x1234");
	app.shrinkTo(0);
	
	jv.asUInteger.value = 0x12345678;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "0x12345678");
	app.shrinkTo(0);
	
	jv.asUInteger.value = 0x123456789;
	builder._putPrettyStringJsonUIntegerImpl(app, jv.asUInteger);
	assert(app.data == "0x0000000123456789");
	app.shrinkTo(0);
	
	
	jv = builder.make(123.5);
	builder._putPrettyStringJsonFloatingPointImpl(app, jv.asFloatingPoint);
	assert(app.data == "123.5");
	app.shrinkTo(0);
	
	jv.asFloatingPoint.positiveSign = true;
	builder._putPrettyStringJsonFloatingPointImpl(app, jv.asFloatingPoint);
	assert(app.data == "+123.5");
	app.shrinkTo(0);
	
	jv.asFloatingPoint.withExponent = true;
	builder._putPrettyStringJsonFloatingPointImpl(app, jv.asFloatingPoint);
	assert(app.data == "+1.235e+2");
	app.shrinkTo(0);
	
	jv.asFloatingPoint.precision = 6;
	builder._putPrettyStringJsonFloatingPointImpl(app, jv.asFloatingPoint);
	assert(app.data == "+1.235000e+2");
	app.shrinkTo(0);
}

@system unittest
{
	Json5Builder builder;
	Json5Value jv;
	auto app = appender!(char[])();
	
	jv = builder.parse(`
		{
		  // comments
		  unquoted: 'and you can quote me on that',
		  singleQuotes: 'I can use "double quotes" here',
		  lineBreaks: "Look, Mom! \
		No \\n's!",
		  hexadecimal: 0xdecaf,
		  leadingDecimalPoint: .8675309, andTrailing: 8675309.,
		  positiveSign: +1,
		  trailingComma: 'in objects', andIn: ['arrays',],
		  "backwardsCompatible": "with JSON",
		}`.chompPrefix("\n").outdent);
	builder.toPrettyString(app, jv, "  ", "\n", Json5Options.escapeNonAscii);
	auto expected = `
		{
		  // comments
		  unquoted: 'and you can quote me on that',
		  singleQuotes: 'I can use "double quotes" here',
		  lineBreaks: "Look, Mom! No \\n's!",
		  hexadecimal: 0x000DECAF,
		  leadingDecimalPoint: .8675309,
		  andTrailing: 8675309.,
		  positiveSign: +1,
		  trailingComma: 'in objects',
		  andIn: [ 'arrays', ],
		  "backwardsCompatible": "with JSON",
		}`.chompPrefix("\n").outdent;
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	
	jv = builder.parse(`{ 'key1': "value1" /* COMMENT1 */, /* COMMENT2 */ key2: 123, "KEY3": 0x1A3F /* COMMENT3 */, }`);
	builder.toPrettyString(app, jv, "  ", "\n");
	expected = `{ 'key1': "value1" /* COMMENT1 */, /* COMMENT2 */ key2: 123, "KEY3": 0x1A3F /* COMMENT3 */, }`;
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	
	jv = builder.make(["test": builder.undefinedValue, "test2": builder.make("TEST2")]);
	builder.toPrettyString(app, jv, "  ", "\n");
	expected = "{\n  \"test2\": \"TEST2\"\n}";
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	
}

@system unittest
{
	Json5Builder builder;
	Json5Value jv;
	Json5Value jv2;
	
	
	jv = builder.make([
		builder.make("TEST1"),
		builder.make("TEST2"),
		builder.make([
			"test1": builder.make(1)
		])
	]);
	jv2 = builder.deepCopy(jv);
	assert(jv2.asArray.value.ptr !is jv.asArray.value.ptr);
	assert(jv2.asArray[0].asString[] == "TEST1");
	assert(jv2.asArray.value.ptr !is jv.asArray.value.ptr);
	assert(jv2.asArray[2].asObject.value.items.ptr !is jv.asArray[2].asObject.value.items.ptr);
	assert(jv2.asArray[2].asObject[0].key.value[] == "test1");
	assert(jv2.asArray[2].asObject[0].value.asInteger.value == 1);
}

@system unittest
{
	import std.datetime: SysTime, DateTime;
	Json5Builder builder;
	Json5Value jv;
	auto app = appender!(char[])();
	
	@kind("Data1") struct Data1
	{
		int a;
		int b;
	}
	auto dat1 = Data1(1, 3);
	jv = builder.serialize(dat1);
	builder.toPrettyString(app, jv, "  ", "\n");
	auto expected = `
	{
	  "a": 1,
	  "b": 3
	}`.chompPrefix("\n").outdent;
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	auto dat1b = builder.deserialize!Data1(builder.parse(expected));
	assert(dat1b.a == dat1.a);
	assert(dat1b.b == dat1.b);
	
	alias ST = SumType!(Data1, int);
	struct Data2
	{
		Json5Value val1;
		StdJsonValue val2;
		int a;
		@name("float_b") float b;
		bool c;
		void* voidData; // ignore as undefined
		immutable(ubyte)[] bin;
		typeof(null) nul;
		string[] strlist;
		string[string] aa;
		Tuple!(int, string) tp;
		@converterSysTime SysTime tim1;
		@converter!(SysTime, StdJsonValue)(
			(src) @safe => SysTime.fromISOExtString(src.str),
			(src) @safe => StdJsonValue(src.toISOExtString())
		) SysTime tim2;
		@converter!(SysTime, Json5Value)(
			(src) @safe => SysTime.fromISOExtString(src.get!string),
			(src) @safe => makeJson(src.toISOExtString())
		) SysTime tim3;
		@converter!(SysTime, immutable(ubyte)[])(
			(src) @trusted => SysTime.fromISOExtString(cast(string)src),
			(src) @trusted => cast(immutable(ubyte)[])(src.toISOExtString())
		) SysTime tim4;
		static struct DataA
		{
			int a;
			Json5Value toJson(ref Json5Builder b) const @safe => b.make(a);
			static DataA fromJson(in Json5Value jv) @safe => DataA(jv.get!int);
		}
		DataA dataA;
		static assert(hasConvertJsonMethodA!DataA);
		static struct DataB
		{
			int a;
			Json5Value toJson() const @safe => makeJson(a);
			static DataB fromJson(in Json5Value jv) @safe => DataB(jv.get!int);
		}
		DataB dataB;
		static assert(hasConvertJsonMethodB!DataB);
		static struct DataC
		{
			int a;
			StdJsonValue toJson() const @safe => StdJsonValue(a);
			static DataC fromJson(in StdJsonValue jv) @safe => DataC(jv.get!int);
		}
		DataC dataC;
		static struct DataD
		{
			int a;
			immutable(ubyte)[] toBinary() const @trusted => (cast(immutable(ubyte)*)&a)[0..4];
			static DataD fromBinary(immutable(ubyte)[] bin) @trusted => DataD(*cast(int*)bin.ptr);
		}
		DataD dataD;
		static assert(hasConvertJsonBinaryMethodA!DataD);
		static struct DataE
		{
			int a;
			immutable(ubyte)[] toRepresentation() const @trusted => (cast(immutable(ubyte)*)&a)[0..4];
			static DataE fromRepresentation(immutable(ubyte)[] bin) @trusted => DataE(*cast(int*)bin.ptr);
		}
		DataE dataE;
		static assert(hasConvertJsonBinaryMethodB!DataE);
		static struct DataF
		{
			int a;
			string toRepresentation() const @safe => to!string(a);
			static DataF fromRepresentation(string str) @safe => DataF(to!int(str));
		}
		DataF dataF;
		static assert(hasConvertJsonBinaryMethodC!DataF);
		ST stVal1;
		ST stVal2;
	}
	auto dat2 = Data2(builder.deepCopy(jv), StdJsonValue.emptyObject, 1, 2, true, null,
		[1,2,3,4], null, ["a", "b"], ["t1":"t2"], tuple(10, "aaa"),
		SysTime(DateTime(2000, 1, 1)), SysTime(DateTime(2001, 1, 1)),
		SysTime(DateTime(2002, 1, 1)), SysTime(DateTime(2004, 1, 1)),
		Data2.DataA(10), Data2.DataB(12), Data2.DataC(14),
		Data2.DataD(20), Data2.DataE(22), Data2.DataF(24),
		ST(Data1(1, 2)), ST(16));
	jv = builder.serialize(dat2);
	assert(jv.asObject["voidData"].type == Json5Type.undefined);
	builder.toPrettyString(app, jv, "  ", "\n");
	expected = `
	{
	  "val1": {
	    "a": 1,
	    "b": 3
	  },
	  "val2": {},
	  "a": 1,
	  "float_b": 2.0,
	  "c": true,
	  "bin": "AQIDBA",
	  "nul": null,
	  "strlist": [
	    "a",
	    "b"
	  ],
	  "aa": {
	    "t1": "t2"
	  },
	  "tp": [
	    10,
	    "aaa"
	  ],
	  "tim1": "2000-01-01T00:00:00",
	  "tim2": "2001-01-01T00:00:00",
	  "tim3": "2002-01-01T00:00:00",
	  "tim4": "MjAwNC0wMS0wMVQwMDowMDowMA",
	  "dataA": 10,
	  "dataB": 12,
	  "dataC": 14,
	  "dataD": "FAAAAA",
	  "dataE": "FgAAAA",
	  "dataF": "24",
	  "stVal1": {
	    "$type": "Data1",
	    "a": 1,
	    "b": 2
	  },
	  "stVal2": 16
	}`.chompPrefix("\n").outdent;
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	Data2 dat2b;
	builder.deserialize(builder.parse(expected), dat2b);
	jv = builder.serialize(dat2);
	builder.toPrettyString(app, jv, "  ", "\n");
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	
}

@system unittest
{
	import std.datetime: SysTime, DateTime;
	Json5Builder builder;
	Json5Value jv;
	auto app = appender!(char[])();
	
	@kind("Data1") struct Data1
	{
		@comment(" TEST")
		int a = 1;
		@integralFormat(false, true)
		int b = 3;
		@unquotedKey @singleQuotedStr
		string txt = "TEST";
		struct A {int a = 10; int b = 20;}
		@unquotedKey @singleLineObj
		A objA;
		@floatingPointFormat(true)
		double c = 0.5;
		@arrayFormat(true, false)
		int[2] ary = [1,2];
		@unquotedKey @singleLineObj struct B { int a = 32; int b = 43; }
		B objB;
	}
	auto expected = `
	{
	  // TEST
	  "a": 1,
	  "b": 0x03,
	  txt: 'TEST',
	  objA: { "a": 10, "b": 20 },
	  "c": .5,
	  "ary": [
	    1,
	    2,
	  ],
	  "objB": { a: 32, b: 43 }
	}`.chompPrefix("\n").outdent;
	auto dat1 = Data1.init;
	static assert(hasAttrJson5Comment!(dat1.tupleof[0]));
	static assert(hasAttrJson5StringFormat!(dat1.tupleof[2]));
	static assert(hasAttrJson5KeyQuotedStyle!(dat1.tupleof[2]));
	jv = builder.serialize(dat1);
	builder.toPrettyString(app, jv, "  ", "\n");
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
}
