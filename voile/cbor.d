/*******************************************************************************
 * CBOR data module
 * 
 * This module provides functionality for working with CBOR (Concise Binary Object Representation) data.
 * It includes definitions for various CBOR data types, a builder for constructing CBOR values,
 * and methods for converting between CBOR and native D types.
 * 
 * See_Also: [RFC 7049](https://tools.ietf.org/html/rfc7049)
 */
module voile.cbor;

import std.sumtype;
import std.range, std.algorithm, std.array, std.traits, std.meta, std.string;
import core.lifetime: move;
import voile.attr;


/*******************************************************************************
 * Determines if the type is binary
 */
enum isBinary(T) = is(T == immutable(ubyte)[]);

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
	import voile.attr: v = value;
	return v(Kind(name, value));
}

/// ditto
auto kind(string value)
{
	import voile.attr: v = value;
	return v(Kind("$type", value));
}

/// ditto
auto kind(string value)()
{
	import voile.attr: v = value;
	return v(Kind("$type", value));
}

private enum hasKind(T) = hasValue!(T, Kind);
private enum getKind(T) = getValues!(T, Kind)[0];

/*******************************************************************************
 * Attribute converting method
 */
auto converter(T1, T2)(void function(in T2, ref T1) from, void function(in T1, ref T2) to)
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
auto converter(T1, T2)(T1 function(T2) from, T2 function(in T1) to)
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
auto converterString(T)(T function(string) from, string function(in T) to)
	=> converter!T(from, to);
/// ditto
alias convStr = converterString;
/// ditto
auto converterBinary(T)(T function(immutable(ubyte)[]) from, immutable(ubyte)[] function(in T) to)
	=> converter!T(from, to);
/// ditto
alias convBin = converterBinary;

/*******************************************************************************
 * Special conveter attributes
 */
auto converterSysTime()
{
	import std.datetime;
	return convStr!SysTime(
		src => SysTime.fromISOExtString(src),
		src => src.toISOExtString());
}
/// ditto
auto converterDateTime()
{
	import std.datetime;
	return convStr!DateTime(
		src => DateTime.fromISOExtString(src),
		src => src.toISOExtString());
}
/// ditto
auto converterDate()
{
	import std.datetime;
	return convStr!Date(
		src => Date.fromISOExtString(src),
		src => src.toISOExtString());
}
/// ditto
auto converterTimeOfDay()
{
	import std.datetime;
	return convStr!TimeOfDay(
		src => TimeOfDay.fromISOExtString(src),
		src => src.toISOExtString());
}
/// ditto
auto converterUUID()
{
	import std.uuid;
	return convStr!UUID(
		src => UUID(src),
		src => src.toString());
}
/// ditto
auto converterDuration()
{
	import core.time;
	return converter!(Duration, CborValue)(
		(in CborValue src, ref Duration dst) { dst = src.get!long.hnsecs; },
		(in Duration src, ref CborValue dst) { dst = src.total!"hnsecs"(); });
}

private enum isArrayWithoutBinary(T) = isArray!T && !isBinary!T;

/*******************************************************************************
 * Determines if the SumType can be serialized to CBOR format
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
	&& Filter!(isArrayWithoutBinary, T.Types).length <= 1
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

private enum hasConvertCborMethodA(T) = is(typeof(T.toCbor(lvalueOf!Builder)) == CborValue)
	&& is(typeof(T.fromCbor(lvalueOf!CborValue)) == T);
private enum hasConvertCborMethodB(T) = is(typeof(T.toCbor()) == CborValue)
	&& is(typeof(T.fromCbor(lvalueOf!CborValue)) == T);
private enum hasConvertCborMethod(T) = hasConvertCborMethodA!T || hasConvertCborMethodB!T;
private enum hasConvertCborBinaryMethodA(T) = is(typeof(T.toBinary()) == immutable(ubyte)[])
	&& is(typeof(T.fromBinary((immutable(ubyte)[]).init)) == T);
private enum hasConvertCborBinaryMethodB(T) = is(typeof(T.toRepresentation()) == immutable(ubyte)[])
	&& is(typeof(T.fromRepresentation((immutable(ubyte)[]).init)) == T);
private enum hasConvertCborBinaryMethodC(T) = is(typeof(T.toRepresentation()) == string)
	&& is(typeof(T.fromRepresentation(string.init)) == T);
private enum hasConvertCborBinaryMethod(T) = hasConvertCborBinaryMethodA!T
	|| hasConvertCborBinaryMethodB!T || hasConvertCborBinaryMethodC!T;
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
	|| (isAggregateType!T && hasConvertCborMethod!T)
	|| (isAggregateType!T && hasConvertCborBinaryMethod!T);
private enum isAccessible(alias var) = __traits(getVisibility, var).startsWith("public", "export") != 0;


/*******************************************************************************
 * Checks if a given type is serializable to CBOR format.
 *
 * This function determines whether a type can be serialized into the CBOR (Concise Binary Object Representation) format.
 * CBOR is a binary data serialization format which aims to provide a more compact representation compared to JSON.
 *
 * Params:
 *   T = The type to check for serializability.
 *
 * Returns:
 *   bool - `true` if the type is serializable to CBOR, `false` otherwise.
 */
template isSerializable(T)
{
	static if (isArray!T && !isBinary!T && !isSomeString!T)
		enum isSerializable = isSerializable!(ElementType!T);
	else static if (isAssociativeArray!T)
		enum isSerializable = isSerializable!(KeyType!T) && isSerializable!(ValueType!T);
	else static if (isSerializableSumType!T)
		enum isSerializable = isSerializable!(KeyType!T) && isSerializable!(ValueType!T);
	else static if (isAggregateType!T && !isSumType!T)
		enum isSerializable = () {
			bool ret = true;
			static foreach (var; Filter!(isAccessible, T.tupleof[]))
				ret &= hasIgnore!var || hasValue!var || isSerializable!(typeof(var));
			return ret;
		}();
	else
		enum isSerializable = isSerializableData!T;
}

/*******************************************************************************
 * The Builder struct is used to generate and manipulate CBOR (Concise Binary Object Representation) data.
 * 
 * - Use the `make` method to create a `CborValue`.
 * - Use the `parse` method to convert binary data to a `CborValue`.
 * - Use the `build` method to convert a `CborValue` to binary format.
 * - The `serialize` and `deserialize` methods support ORM (Object-Relational Mapping).
 */
struct Builder
{
private:
	enum String: string { init = string.init }
	enum Binary: immutable(ubyte)[] { init = (immutable(ubyte)[]).init }
	enum Undefined { init }
	enum Null { init }
	enum HalfFloat: ushort { init = 0, nan = 0x7E00, infinity = 0x7C00 }
	enum SingleFloat: float { init = 0, nan = float.nan, inifinity = float.infinity }
	enum DoubleFloat: double { init = 0, nan = double.nan, inifinity = double.infinity }
	enum PositiveInteger: ulong { init = 0 }
	enum NegativeInteger: ulong { init = 0 }
	enum Boolean: bool { init = 0 }
	static T convToFloat(T)(HalfFloat fp) @safe
	if (is(T == float))
	{
		ushort h = cast(ushort)fp;
		uint sign = (h & 0x8000) << 16; // 符号ビット（ビット 31）
		uint exponent = (h & 0x7C00) >> 10; // 指数部
		uint mantissa = (h & 0x03FF); // 仮数部
		
		if (exponent == 0)
		{
			// サブノーマル
			if (mantissa == 0)
				return (() @trusted => *cast(T*)&sign)(); // ±0.0
			while ((mantissa & 0x0400) == 0)
			{
				// 正規化
				mantissa <<= 1;
				exponent--;
			}
			mantissa &= 0x03FF;
			exponent = 1;
		}
		else if (exponent == 31)
		{
			// Infinity or NaN
			exponent = 255;
		}
		else
		{
			// 通常の数
			exponent += (127 - 15); // binary16 → binary32 のバイアス調整
		}
		
		uint result = sign | (exponent << 23) | (mantissa << 13);
		return (() @trusted => *cast(float*)&result)(); // ビットパターンを float に変換
	}
	/// ditto
	static T convToFloat(T)(HalfFloat fp) @safe
	if (is(T == double))
	{
		ushort h = cast(ushort)fp;
		ulong sign = ulong(h & 0x8000) << 48; // 符号ビット（ビット 31）
		ulong exponent = (h & 0x7C00) >> 10; // 指数部
		ulong mantissa = (h & 0x03FF); // 仮数部
		
		if (exponent == 0)
		{
			// サブノーマル
			if (mantissa == 0)
				return (() @trusted => *cast(T*)&sign)(); // ±0.0
			while ((mantissa & 0x0400) == 0)
			{
				// 正規化
				mantissa <<= 1;
				exponent--;
			}
			mantissa &= 0x03FF;
			exponent = 1;
		}
		else if (exponent == 31)
		{
			// Infinity or NaN
			exponent = 2047;
		}
		else
		{
			// 通常の数
			exponent += (1023 - 15); // binary16 → binary64 のバイアス調整
		}
		
		ulong result = sign | (exponent << 52) | (mantissa << 42);
		return (() @trusted => *cast(double*)&result)(); // ビットパターンを double に変換
	}
	/// ditto
	static real convToFloat(T)(HalfFloat fp) @safe
	if (is(T == real))
	{
		return cast(real)convToFloat!double(fp);
	}
	
	@safe unittest
	{
		import std.math: isNaN, isInfinity, isClose;
		// Test for zero
		assert(convToFloat!float(cast(HalfFloat)cast(HalfFloat)0x0000) == 0.0f);
		assert(convToFloat!double(cast(HalfFloat)cast(HalfFloat)0x0000) == 0.0f);
		// Test for subnormal numbers
		assert(convToFloat!float(cast(HalfFloat)0x0001) == float.min_normal);
		assert(convToFloat!double(cast(HalfFloat)0x0001) == double.min_normal);
		
		// Test for normal numbers
		assert(convToFloat!float(cast(HalfFloat)0x3C00) == 1.0f);
		assert(convToFloat!double(cast(HalfFloat)0x3C00) == 1.0);
		
		// Test for infinity
		assert(convToFloat!float(cast(HalfFloat)0x7C00) == float.infinity);
		assert(convToFloat!double(cast(HalfFloat)0x7C00) == double.infinity);
		
		// Test for NaN
		assert(convToFloat!float(cast(HalfFloat)0x7E00).isNaN);
		assert(convToFloat!double(cast(HalfFloat)0x7E00).isNaN);
		
		// Test for negative zero
		assert(convToFloat!float(cast(HalfFloat)0x8000) == -0.0f);
		assert(convToFloat!double(cast(HalfFloat)0x8000) == -0.0);
		
		// Test for negative infinity
		assert(convToFloat!float(cast(HalfFloat)0xFC00) == -float.infinity);
		assert(convToFloat!double(cast(HalfFloat)0xFC00) == -double.infinity);
		
		// Test for negative normal numbers
		assert(convToFloat!float(cast(HalfFloat)0xBC00) == -1.0f);
		assert(convToFloat!double(cast(HalfFloat)0xBC00) == -1.0);
		
		// Test for negative subnormal numbers
		assert(convToFloat!float(cast(HalfFloat)0x8001) == -float.min_normal);
		assert(convToFloat!double(cast(HalfFloat)0x8001) == -double.min_normal);
	}
	
	static struct Dictionary(K, V)
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
		auto append(ref K k, ref V v) => items ~= Item(k, v);
		///
		auto append(K k, V v) => items ~= Item(k, v);
		///
		auto get(K k, lazy V defaultValue = V.init) @trusted
		{
			foreach (ref e; items)
				if (e.key == k)
					return e.value;
			return defaultValue;
		}
	}
	template Array(T) { enum Array: T[] { init = T[].init } }
	
	auto allocStr() => String.init;
	auto allocDic(K, V)() => Dictionary!(K, V).init;
	auto allocAry(T)() => Array!T.init;
	T[] copyMemory(T)(const(T)[] src) const => src.dup;
	immutable(T)[] copyImmutableMemory(T)(const(T)[] src) const => src.idup;
	enum DummyMap: Dictionary!(int, int) { init = Dictionary!(int, int).init }
public:
	/***************************************************************************
	 * CborValue
	 */
	static struct CborValue
	{
	private:
		alias CborArray = Array!CborValue;
		alias CborMap = DummyMap;
		alias CborType = SumType!(
			Undefined,
			Null,
			Boolean,
			PositiveInteger,
			NegativeInteger,
			HalfFloat,
			SingleFloat,
			DoubleFloat,
			String,
			Binary,
			CborArray,
			CborMap);
		ref inout(Dictionary!(CborValue, CborValue)) _reqMap() pure inout @trusted
		{
			alias tmp = __traits(getMember, CborType, "get");
			return *cast(inout(Dictionary!(CborValue, CborValue))*)&(__traits(child, _instance, tmp!CborMap)());
		}
		inout(CborValue)[] _reqArray() pure inout @trusted
		{
			alias tmp = __traits(getMember, CborType, "get");
			return cast(inout(CborValue)[])__traits(child, _instance, tmp!CborArray)();
		}
		string _reqStr() pure inout @trusted
		{
			alias tmp = __traits(getMember, CborType, "get");
			return cast(string)__traits(child, _instance, tmp!String)();
		}
		immutable(ubyte)[] _reqBin() pure inout @trusted
		{
			alias tmp = __traits(getMember, CborType, "get");
			return cast(immutable(ubyte)[])__traits(child, _instance, tmp!Binary)();
		}
	public:
		///
		enum Type: ubyte
		{
			undefined,
			nullValue,
			boolean,
			positive,
			negative,
			float16,
			float32,
			float64,
			string,
			binary,
			array,
			map,
		}
	private:
		CborType _instance;
		Builder* _builder;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(T)(T value, ref Builder builder) @trusted
		{
			_builder = &builder;
			opAssign(value);
		}
		
		/***********************************************************************
		 * Type getter
		 */
		Type type() const pure nothrow @safe
		{
			return cast(Type)__traits(getMember, _instance, "tag");
		}
		
		/***********************************************************************
		 * Destructor
		 */
		~this() pure nothrow @nogc @safe
		{
		}
		
		/***********************************************************************
		 * Assign operator
		 */
		ref CborValue opAssign(T)(T value) pure return @trusted
		{
			static if (is(T == CborValue))
			{
				_instance = value._instance;
				_builder  = value._builder;
			}
			else static if (isIntegral!T && isSigned!T && !is(T == enum))
				_instance = value < 0
					? CborType(cast(NegativeInteger)cast(ulong)(-1-value))
					: CborType(cast(PositiveInteger)cast(ulong)value);
			else static if (isIntegral!T && isUnsigned!T && !is(T == enum))
				_instance = cast(PositiveInteger)value;
			else static if (is(T == bool))
				_instance = cast(Boolean)value;
			else static if (is(T == float))
				_instance = cast(SingleFloat)value;
			else static if (is(T == double))
				_instance = cast(DoubleFloat)value;
			else static if (isSomeString!T)
				_instance = cast(String)value;
			else static if (isBinary!T)
				_instance = cast(Binary)value;
			else static if (is(T == typeof(null)))
				_instance = Null.init;
			else static if (isArray!T && !is(T == enum))
			{
				auto ary = builder.allocAry!CborValue;
				foreach (e; value)
					ary ~= CborValue(e, builder);
				_instance = ary.move;
			}
			else static if (isAssociativeArray!T)
			{
				auto map = builder.allocDic!(CborValue, CborValue);
				foreach (ref k, ref v; value)
					map.append(CborValue(k, builder), CborValue(v, builder));
				_instance = (*cast(CborMap*)&map).move;
			}
			else static if (is(T == Dictionary!(CborValue, CborValue)))
				_instance = (*cast(CborMap*)&value).move;
			else
				_instance = value;
			return this;
		}
		
		/***********************************************************************
		 * Null check
		 */
		bool isNull() const pure nothrow @safe
		{
			//return _instance.match!((ref Null v) @trusted => true, (ref _) @trusted => false);
			return type == Type.nullValue;
		}
		
		/***********************************************************************
		 * Undefined check
		 */
		bool isUndefined() const pure nothrow @safe
		{
			//return _instance.match!((ref Undefined v) => true, (ref _) => false);
			return type == Type.undefined;
		}
		
		/***********************************************************************
		 * Overflow number check
		 * 
		 * CBOR supports signed integers, but the range it can handle differs from D's long type.
		 * This function determines whether a CBOR signed integer exceeds the range of D's long type.
		 * Specifically, the range of CBOR integers is -ulong.max(-1-2^64) to ulong.max(2^64).
		 * In contrast, the range of D's long type is long.min(-1-2^63) to long.max(2^63),
		 * and the range of the ulong type is 0 to ulong.max(2^64).
		 */
		bool isOverflowedInteger() const pure nothrow @trusted
		{
			return _instance.match!(
				(PositiveInteger v) nothrow => cast(ulong)v > long.max,
				(NegativeInteger v) nothrow => cast(ulong)v > long.max,
				(_) nothrow => false);
		}
		
		/***********************************************************************
		 * Retrieve the value as a D language type
		 * 
		 * Since the types handled by CBOR may not match the types in the D language, conversion is performed.
		 * Specify the type with T or a default value, and return the converted type.
		 * For example, if the long type is specified, CBOR's positive and negative integers,
		 * as well as floating-point numbers, are cast and converted to the long type. Strings are also
		 * parsed and converted to integers.
		 */
		T get(T)(lazy T defaultValue = T.init) const nothrow @safe
		{
			import voile.misc: get;
			import std.conv: to;
			try
			{
				static if (is(T == CborValue))
					return this;
				else static if (isIntegral!T)
					return _instance.match!(
						(in PositiveInteger v) @trusted => cast(T)v,
						(in NegativeInteger v) @trusted => cast(T)(long(-1)-cast(long)cast(ulong)v),
						(in SingleFloat v) @trusted     => cast(T)cast(float)v,
						(in DoubleFloat v) @trusted     => cast(T)cast(double)v,
						(in String v) @trusted          => to!T(cast(string)v),
						(in _) @trusted                 => defaultValue);
				else static if (is(T == bool))
					return _instance.match!(
						(in PositiveInteger v) @trusted => cast(ulong)v != 0,
						(in NegativeInteger v) @trusted => cast(ulong)v != 0,
						(in String v) @trusted          => (cast(string)v).length != 0,
						(in CborArray v) @trusted       => v.length != 0,
						(in CborMap v) @trusted         => v.items.length != 0,
						(in Undefined v) @trusted       => false,
						(in Null v) @trusted            => false,
						(in Boolean v) @trusted         => cast(bool)v,
						(in _) @trusted                 => defaultValue);
				else static if (isFloatingPoint!T)
					return _instance.match!(
						(in PositiveInteger v) @trusted => cast(T)v,
						(in NegativeInteger v) @trusted => cast(T)(long(-1)-cast(long)cast(ulong)v),
						(in String v) @trusted          => to!T(cast(string)v),
						(in HalfFloat v) @trusted       => convToFloat!T(v),
						(in SingleFloat v) @trusted     => cast(T)cast(float)v,
						(in DoubleFloat v) @trusted     => cast(T)cast(double)v,
						(in _) @trusted                 => defaultValue);
				else static if (is(T == string))
					return _instance.match!(
						(in String v) @trusted          => cast(string)v,
						(in PositiveInteger v) @trusted => to!string(cast(ulong)v),
						(in NegativeInteger v) @trusted => to!string(long(-1)-cast(long)cast(ulong)v),
						(in Boolean v) @trusted         => to!string(cast(bool)v),
						(in HalfFloat v) @trusted       => to!string(convToFloat!double(v)),
						(in SingleFloat v) @trusted     => to!string(cast(float)v),
						(in DoubleFloat v) @trusted     => to!string(cast(double)v),
						(in _) @trusted                 => defaultValue);
				else static if (is(T == immutable(ubyte)[]))
					return _instance.match!(
						(in PositiveInteger v) @trusted => _builder.copyImmutableMemory((cast(ubyte*)&v)[0..PositiveInteger.sizeof]),
						(in NegativeInteger v) @trusted => _builder.copyImmutableMemory((cast(ubyte*)&v)[0..NegativeInteger.sizeof]),
						(in Binary v) @trusted          => cast(immutable(ubyte)[])v,
						(in String v) @trusted          => cast(immutable(ubyte)[])cast(string)v,
						(in HalfFloat v) @trusted       => _builder.copyImmutableMemory((cast(ubyte*)&v)[0..HalfFloat.sizeof]),
						(in SingleFloat v) @trusted     => _builder.copyImmutableMemory((cast(ubyte*)&v)[0..SingleFloat.sizeof]),
						(in DoubleFloat v) @trusted     => _builder.copyImmutableMemory((cast(ubyte*)&v)[0..DoubleFloat.sizeof]),
						(in _) @trusted                 => defaultValue);
				else static if (isArray!T && !is(T == enum))
				{
					T ret;
					foreach (e; _reqArray)
						ret ~= e.get!(ElementType!T);
					return ret;
				}
				else static if (isAssociativeArray!T)
				{
					T ret;
					alias V = ValueType!T;
					alias K = KeyType!T;
					foreach (e; _reqMap.byKeyValue)
						ret[e.key.get!K] = e.value.get!V;
					return ret;
				}
				else
					return (() @trusted => (cast()_instance).match!((ref T v) => v, (ref _) => defaultValue))();
			}
			catch (Exception e)
			{
				try
					return defaultValue;
				catch (Exception e2)
					return T.init;
			}
		}
		
		/***********************************************************************
		 * 
		 */
		ref T require(T, K)(K key) nothrow
		{
			try
			{
				return _instance.match!(
					(ref CborMap v) @trusted {
						foreach (ref kv; v.items)
							if (kv.key.get!K == name)
								return kv.value.get!T;
						v.append(CborValue(key, _builder));
						return v.items[$-1].value;
					},
					(ref _) @trusted {
						CborMap v;
						v.append(CborValue(key, _builder), CborValue.init);
						auto items = v.items;
						_instance = v.move;
						return items[$-1].value;
					}
				);
			}
			catch (Exception e)
			{
			}
			CborMap v;
			v.append(CborValue(key, _builder), CborValue.init);
			auto items = v.items;
			_instance = v.move;
			return items[$-1].value;
		}
		
		/***********************************************************************
		 * 
		 */
		T getValue(T, K)(K key, lazy T defaultValue = T.init) const nothrow
		{
			try
			{
				return _instance.match!(
					(in CborMap v) @trusted {
						foreach (ref kv; _reqMap.items)
							if (kv.key.get!K == key)
								return kv.value.get!T;
						return defaultValue;
					},
					(in _) @trusted => defaultValue
				);
			}
			catch (Exception e)
			{
				try
					return defaultValue;
				catch (Exception e2)
					return T.init;
			}
		}
		
		/***********************************************************************
		 * Get the builder instance.
		 */
		ref Builder builder() pure nothrow @safe
		{
			return *_builder;
		}
	}
	
	/***************************************************************************
	 * Create a CborValue from a given value.
	 */
	CborValue make(T)(T value) @safe
	{
		return CborValue(value, this);
	}
	
	/***************************************************************************
	 * Create a CborValue of empty array.
	 */
	CborValue emptyArray() pure nothrow @safe
	{
		return CborValue(CborValue.CborArray.init, this);
	}
	
	/***************************************************************************
	 * Create a CborValue of empty map.
	 */
	CborValue emptyMap() pure nothrow @safe
	{
		return CborValue(CborValue.CborMap.init, this);
	}
	
	/***************************************************************************
	 * Create a CborValue of null.
	 */
	CborValue nullValue() pure nothrow @safe
	{
		return CborValue(null, this);
	}
	
	/***************************************************************************
	 * Create a CborValue of undefined.
	 */
	CborValue undefinedValue() pure nothrow @safe
	{
		return CborValue(Undefined.init, this);
	}
	
	/***************************************************************************
	 * Deep copy a CborValue.
	 */
	CborValue deepCopy(CborValue src) pure @safe
	{
		if (src._builder is &this)
			return src;
		return src._instance.match!(
			(ref CborValue.CborArray ary)
			{
				CborValue.CborArray dst;
				foreach (ref e; ary)
					dst ~= deepCopy(e);
				return CborValue(dst, this);
			},
			(ref CborValue.CborMap map) @trusted
			{
				auto dst = allocDic!(CborValue, CborValue);
				foreach (ref e; src._reqMap.byKeyValue)
					dst.append(deepCopy(e.key), deepCopy(e.value));
				return CborValue(dst, this);
			},
			(ref Binary bin) => CborValue(copyImmutableMemory(cast(immutable(ubyte)[])bin), this),
			(ref String str) => CborValue(copyImmutableMemory(cast(string)str), this),
			(ref _) => CborValue(src._instance, this)
		);
	}
	
	///
	@safe unittest
	{
		Builder b1;
		Builder b2;
		immutable str = "123";
		auto v1 = b1.make(str);
		assert(v1.get!string is str);
		auto v2 = b1.deepCopy(v1);
		assert(v2.get!string is str);
		// Check if the copied value is a new instance
		auto v3 = b2.deepCopy(v1);
		assert(v3.get!string !is v1.get!string);
	}
	
	@safe unittest
	{
		Builder b1;
		Builder b2;
		auto v1 = b1.make(["1", "2", "3"]);
		auto v2 = b2.deepCopy(v1);
		
		immutable(ubyte)[] bin = [0x01, 0x02, 0x03];
		v1 = b1.make(bin);
		v2 = b2.deepCopy(v1);
		
		v1 = b1.make([1: "1", 2: "2", 3: "3"]);
		v2 = b2.deepCopy(v1);
	}
	
	/***************************************************************************
	 * Parse a binary CBOR data to a CborValue.
	 */
	size_t parse(ref CborValue dst, immutable(ubyte)[] src) @safe
	{
		if (src.length == 0)
			return 0;
		immutable ubyte head = src[0];
		immutable ubyte major = head >> 5;
		immutable ubyte minor = head & 0x1F;
		auto data = src[1..$];
		ulong argument;
		if (minor < 24)
		{
			// Simple value
			argument = minor;
		}
		else if (minor == 24)
		{
			argument = data[0];
		}
		else if (minor == 25 && data.length >= 2)
		{
			argument = (ushort(data[0]) << 8) | data[1];
			data = data[2 .. $];
		}
		else if (minor == 26 && data.length >= 4)
		{
			argument = (uint(data[0]) << 24) | (uint(data[1]) << 16) |
				(uint(data[2]) << 8) | data[3];
			data = data[4 .. $];
		}
		else if (minor == 27 && data.length >= 8)
		{
			argument = (ulong(data[0]) << 56) | (ulong(data[1]) << 48) |
				(ulong(data[2]) << 40) | (ulong(data[3]) << 32) |
				(ulong(data[4]) << 24) | (ulong(data[5]) << 16) |
				(ulong(data[6]) << 8) | ulong(data[7]);
			data = data[8 .. $];
		}
		else if (minor == 31)
		{
			// Break stop code, used for indefinite-length items
			return 1;
		}
		else
		{
			// Reserved values (28-30) are not well-formed CBOR
			return 0;
		}
		
		switch (major)
		{
		case 0: // Unsigned integer
			dst = CborValue(cast(PositiveInteger)argument, this);
			break;
		case 1: // Negative integer (-1 - argument)
			dst = CborValue(cast(NegativeInteger)argument, this);
			break;
		case 2: // Byte string
			if (argument < data.length)
				return 0;
			dst = CborValue(cast(Binary)data[0 .. cast(size_t)argument], this);
			data = data[cast(size_t)argument .. $];
			break;
		case 3: // Text string (UTF-8 encoded)
			if (argument > data.length)
				return 0;
			dst = CborValue(cast(String)cast(string)data[0 .. cast(size_t)argument], this);
			data = data[cast(size_t)argument .. $];
			break;
		case 4: // Array (number of elements given by argument)
			CborValue.CborArray tmpAry;
			foreach (i; 0 .. argument)
			{
				CborValue tmp;
				auto consume = parse(tmp, data);
				if (consume == 0)
					return 0;
				tmpAry ~= tmp;
				data = data[consume .. $];
			}
			dst = CborValue(tmpAry.move, this);
			break;
		case 5: // Map (number of key-value pairs given by argument)
			auto map = allocDic!(CborValue, CborValue);
			foreach (i; 0 .. argument)
			{
				CborValue key;
				CborValue value;
				auto consume = parse(key, data);
				if (consume == 0)
					return 0;
				data = data[consume .. $];
				consume = parse(value, data);
				if (consume == 0)
					return 0;
				data = data[consume .. $];
				map.append(key, value);
			}
			(() @trusted => dst = CborValue((*cast(CborValue.CborMap*)&map).move, this))();
			break;
		case 6: // Tag
			return 0;
		case 7: // Simple/Float
			if (minor == 20) // False
				dst = CborValue(cast(Boolean)false, this);
			else if (minor == 21) // True
				dst = CborValue(cast(Boolean)true, this);
			else if (minor == 22) // Null
				dst = CborValue(Null.init, this);
			else if (minor == 23) // Undefined
				dst = CborValue(Undefined.init, this);
			else if (minor == 25) // 16-bit float
				dst = CborValue(cast(HalfFloat)cast(ushort)argument, this);
			else if (minor == 26) // 32-bit float
				dst = CborValue(cast(SingleFloat)(() @trusted => *cast(float*)&argument)(), this);
			else if (minor == 27) // 64-bit float
				dst = CborValue(cast(DoubleFloat)(() @trusted => *cast(double*)&argument)(), this);
			else
				dst = CborValue(cast(PositiveInteger)argument, this);
			break;
		default:
			return 0;
		}
		assert(src.length >= data.length);
		return src.length - data.length;
	}
	/// ditto
	bool parse(OutputRange)(ref OutputRange dst, immutable(ubyte)[] src) @safe
	{
		auto data = src[];
		bool parsed;
		while (data.length > 0)
		{
			CborValue tmp;
			auto consume = parse(data, tmp);
			if (consume == 0)
				return false;
			dst.put(tmp);
			assert(data.length >= consume);
			data = data[consume .. $];
			parsed = true;
		}
		return parsed;
	}
	/// ditto
	CborValue parse(ref immutable(ubyte)[] src) @safe
	{
		CborValue ret;
		auto consume = parse(ret, src);
		if (consume == 0)
			return CborValue.init;
		src = src[consume .. $];
		return ret;
	}
	/// ditto
	CborValue parse(ref ubyte[] src) @trusted
	{
		CborValue ret;
		auto mem = copyImmutableMemory(src);
		auto consume = parse(ret, mem);
		if (consume == 0)
			return CborValue.init;
		src = src[consume .. $];
		return ret;
	}
	
	///
	@safe unittest
	{
		Builder b;
		immutable(ubyte)[] data = [0x63, 'f', 'o', 'o', 0x43, 0x01, 0x02, 0x03];
		auto v1 = b.parse(data);
		assert(v1.get!string == "foo");
		assert(data == [0x43, 0x01, 0x02, 0x03]);
		auto v2 = b.parse(data);
		assert(v2.get!(immutable(ubyte)[]) == [1, 2, 3]);
		assert(data.length == 0);
	}
	
	/***************************************************************************
	 * Build a CborValue to a binary CBOR data.
	 */
	void build(OutputRange)(ref OutputRange dst, CborValue src) @safe
	if (isOutputRange!(OutputRange, ubyte))
	{
		import std.conv: to;
		
		void writeUInt(ulong data, ubyte major) @safe
		{
			if (data < 24)
				dst.put(cast(ubyte)(major << 5 | data));
			else if (data < 256)
			{
				dst.put(cast(ubyte)(major << 5 | 24));
				dst.put(cast(ubyte)data);
			}
			else if (data < 65536)
			{
				dst.put(cast(ubyte)(major << 5 | 25));
				dst.put(cast(ubyte)(data >> 8));
				dst.put(cast(ubyte)data);
			}
			else if (data < 4294967296)
			{
				dst.put(cast(ubyte)(major << 5 | 26));
				dst.put(cast(ubyte)(data >> 24));
				dst.put(cast(ubyte)(data >> 16));
				dst.put(cast(ubyte)(data >> 8));
				dst.put(cast(ubyte)data);
			}
			else
			{
				dst.put(cast(ubyte)(major << 5 | 27));
				dst.put(cast(ubyte)(data >> 56));
				dst.put(cast(ubyte)(data >> 48));
				dst.put(cast(ubyte)(data >> 40));
				dst.put(cast(ubyte)(data >> 32));
				dst.put(cast(ubyte)(data >> 24));
				dst.put(cast(ubyte)(data >> 16));
				dst.put(cast(ubyte)(data >> 8));
				dst.put(cast(ubyte)data);
			}
		}
		void writeFloat(ulong data, ubyte major) @safe
		{
			writeUInt(data, major);
		}
		void writeString(string data) @safe
		{
			writeUInt(data.length, 3);
			dst.put(cast(immutable(ubyte)[])data);
		}
		void writeBinary(immutable(ubyte)[] data) @safe
		{
			writeUInt(data.length, 2);
			dst.put(data);
		}
		void writeArray(CborValue.CborArray data) @safe
		{
			writeUInt(data.length, 4);
			foreach (e; data)
				build(dst, e);
		}
		void writeMap(ref CborValue.CborMap data) @trusted
		{
			writeUInt(data.items.length, 5);
			foreach (e; (*cast(Dictionary!(CborValue, CborValue)*)&data).items)
			{
				build(dst, e.key);
				build(dst, e.value);
			}
		}
		src._instance.match!(
			(ref Undefined v)             => dst.put(ubyte(0xF7)),
			(ref Null v)                  => dst.put(ubyte(0xF6)),
			(ref Boolean v)               => dst.put(ubyte(cast(bool)v ? 0xF5 : 0xF4)),
			(ref PositiveInteger v)       => writeUInt(cast(ulong)v, 0),
			(ref NegativeInteger v)       => writeUInt(cast(ulong)v, 1),
			(ref HalfFloat v)             => writeFloat(cast(ulong)cast(ushort)v, 7),
			(ref SingleFloat v) @trusted  => writeFloat(cast(ulong)*cast(uint*)&v, 7),
			(ref DoubleFloat v) @trusted  => writeFloat(*cast(ulong*)&v, 7),
			(ref String v)                => writeString(cast(string)v),
			(ref Binary v)                => writeBinary(cast(immutable(ubyte)[])v),
			(ref CborValue.CborArray v)   => writeArray(v),
			(ref CborValue.CborMap v)     => writeMap(v)
		);
	}
	/// ditto
	immutable(ubyte)[] build(CborValue src) @safe
	{
		auto app = appender!(immutable ubyte[]);
		build(app, src);
		return app.data;
	}
	
	///
	@safe unittest
	{
		Builder b;
		auto v1 = b.make("foo");
		auto data = b.build(v1);
		assert(data == [0x63, 'f', 'o', 'o']);
	}
	
	/***************************************************************************
	 * Serialize a various data to CborValue.
	 * 
	 * The serialize function generates a CborValue instance from the given data.
	 * The data type must be one of the following.
	 * 
	 * - CborValue
	 * - Integral type (int, uint, long, ulong, short, ushort, byte, ubyte)
	 * - Floating point type (float, double)
	 * - bool
	 * - string
	 * - binary (immutable(ubyte)[])
	 * - null
	 * - Array
	 *   - Recursively serialized
	 * - AssociativeArray
	 *   - Recursively serialized
	 * - SumType
	 *   - Converted to a map type CborValue
	 *     - All types have the @kind attribute
	 *   - Recursively serialized
	 * - Aggregate type (struct, class, union): meets one of the following conditions
	 *   - Composed of simple public member variables
	 *     - Converted to a map type CborValue
	 *     - Recursively serialized
	 *     - If the @ignore attribute is present, do not serialize
	 *     - If the @ignoreIf attribute is present, do not serialize if the condition is met
	 *     - If the @name attribute is present, use that name
	 *     - If the @value attribute is present, use that value
	 *     - If the @converter attribute is present, use that conversion proxy
	 *   - toCbor/fromCbor methods, where fromCtor is a static method
	 *   - toBinary/fromBinary methods, where fromBinary is a static method
	 *   - toRepresentation/fromRepresentation methods, where fromRepresentation is a static method
	 */
	CborValue serialize(T)(T value) @safe
	{
		static if (is(T == CborValue))
			return value;
		else static if (isBinary!T)
			return CborValue(value, this);
		else static if (isArray!T && isSerializable!(ElementType!T))
		{
			auto ary = allocAry!CborValue();
			foreach (e; value)
				ary ~= serialize(e);
			return CborValue(ary, this);
		}
		else static if (isAssociativeArray!T && isSerializable!(KeyType!T) && isSerializable!(ValueType!T))
		{
			auto map = allocDic!(CborValue, CborValue)();
			foreach (k, v; value)
				map.append(serialize(k), serialize(v));
			return CborValue(map, this);
		}
		else static if (isSerializableSumType!T)
		{
			// SumTypeの場合
			// AggregateTypeの場合は、@kind属性で指定された値を付与して判別に用いる
			// それ以外の場合は、整数、実数、文字列、バイナリ、真偽値のいずれかがユニークでなければならない
			return value.match!(
				(ref e)
				{
					static if (isAggregateType!(typeof(e)) && hasKind!(typeof(e)))
					{
						alias Map = Dictionary!(CborValue, CborValue);
						auto map = serialize(e);
						enum kind = getKind!(typeof(e));
						map._reqMap.items = Map.Item(CborValue(kind.key, this), CborValue(kind.value, this))
							~ map._reqMap.items;
						return map;
					}
					else
					{
						return serialize(e);
					}
				}
			);
		}
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborMethodA!T)
			return value.toCbor(this);
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborMethodB!T)
			return deepCopy(value.toCbor());
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborBinaryMethodA!T)
			return CborValue(value.toBinary(), this);
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborBinaryMethodB!T)
			return CborValue(value.toRepresentation(), this);
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborBinaryMethodC!T)
			return CborValue(value.toRepresentation(), this);
		else static if (isAggregateType!T && isSerializable!T)
		{
			auto map = allocDic!(CborValue, CborValue)();
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
					alias appendMap = ()
					{
						static if (hasName!e)
							alias getname = () => CborValue(getName!e, this);
						else
							alias getname = () => CborValue(e.stringof, this);
						static if (hasConvBy!e && canConvTo!(e, string))
							alias getval = () @trusted => make(convTo!(e, string)(value.tupleof[i]));
						else static if (hasConvBy!e && canConvTo!(e, immutable(ubyte)[]))
							alias getval = () @trusted => CborValue(convTo!(e, immutable(ubyte)[])(value.tupleof[i]), this);
						else static if (hasConvBy!e && canConvTo!(e, CborValue))
							alias getval = () @trusted { auto cv = nullValue; convertTo!e(value.tupleof[i], cv); return cv; };
						else static if (hasValue!e)
							alias getval = () => serialzie(getValue!e);
						else
							alias getval = () => serialize(value.tupleof[i]);
						map.append(getname(), getval());
					};
					static if (hasIgnoreIf!e)
					{
						if (!getPredIgnoreIf!e(value.tupleof[i]))
							appendMap();
					}
					else
					{
						appendMap();
					}
				}}
			}
			return CborValue(map, this);
		}
		else static if(__traits(compiles, CborValue(value, this)))
			return CborValue(value, this);
		else
			return CborValue.init;
	}
	
	///
	@safe unittest
	{
		Builder b;
		struct Foo
		{
			int x;
			string y;
		}
		static assert(isSerializable!Foo);
		auto foo = Foo(42, "foo");
		auto v = b.serialize(foo);
		assert(v.getValue!int("x") == 42);
		assert(v.getValue!string("y") == "foo");
	}
	
	/***************************************************************************
	 * Deserialize a CborValue to a various data.
	 * 
	 * The deserialize function generates value from CborValue instance.
	 * The data type must be one of the following.
	 * 
	 * - CborValue
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
	 *   - Converted from a map type CborValue
	 *     - All types have the @kind attribute
	 *   - Recursively deserialized
	 * - Aggregate type (struct, class, union): meets one of the following conditions
	 *   - Composed of simple public member variables
	 *     - Converted to a map type CborValue
	 *     - Recursively deserialized
	 *     - If the @ignore attribute is present, do not deserialize
	 *     - If the @ignoreIf attribute is present, do not deserialize if the condition is met
	 *     - If the @name attribute is present, use that name
	 *     - If the @converter attribute is present, use that conversion proxy
	 *     - If the @essential attribute is present, throw an exception if deserialization fails
	 *   - toCbor/fromCbor methods, where fromCtor is a static method
	 *   - toBinary/fromBinary methods, where fromBinary is a static method
	 *   - toRepresentation/fromRepresentation methods, where fromRepresentation is a static method
	 */
	bool deserialize(T)(in CborValue src, ref T dst) @safe
	{
		static if (is(T == CborValue))
			dst = deepCopy(src);
		else static if (isBinary!T)
			dst = src.get!T;
		else static if (isArray!T && isSerializable!(ElementType!T))
		{
			// 配列
			dst.length = src._reqArray.length;
			foreach (i, ref e; src._reqArray)
			{
				if (!deserialize(e, dst[i]))
					return false;
			}
		}
		else static if (isAssociativeArray!T && isSerializable!(KeyType!T) && isSerializable!(ValueType!T))
		{
			// 連想配列
			foreach (e; src._reqMap.byKeyValue)
			{
				KeyType!T key;
				ValueType!T value;
				if (!deserialize(e.key, key) || !deserialize(e.value, value))
					return false;
				dst[key] = value;
			}
		}
		else static if (isSerializableSumType!T)
		{
			// SumType
			switch (src.type)
			{
			case CborType.map:
				immutable kinds = [staticMap!(getKind, Filter!(isAggregateType, T.Types))];
				size_t kindIdx = -1;
				static if (kinds.length)
				{
					foreach (i, ref e; src._reqMap.items)
					{
						foreach (kind; kinds)
						{
							if (e.key._reqStr == kind.key && e.value._reqStr == kind.value)
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
							if (!deserialize(src, ret))
								return false;
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
						if (!deserialize(src, ret))
							return false;
						(() @trusted => dst = ret.move)();
					}
				}
				break;
			case CborType.array:
					alias Types = Filter!(isArrayWithoutBinary, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						if (!deserialize(src, ret))
							return false;
						(() @trusted => dst = ret.move)();
					}
				break;
			case CborType.boolean:
					alias Types = Filter!(isBoolean, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						if (!deserialize(src, ret))
							return false;
						(() @trusted => dst = ret.move)();
					}
				break;
			case CborType.positive:
			case CborType.negative:
					alias Types = Filter!(isIntegral, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						if (!deserialize(src, ret))
							return false;
						(() @trusted => dst = ret.move)();
					}
				break;
			case CborType.string:
					alias Types = Filter!(isSomeString, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						if (!deserialize(src, ret))
							return false;
						(() @trusted => dst = ret.move)();
					}
				break;
			case CborType.binary:
					alias Types = Filter!(isBinary, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						if (!deserialize(src, ret))
							return false;
						(() @trusted => dst = ret.move)();
					}
				break;
			default:
			}
		}
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborMethod!T)
			dst = T.fromCbor(src);
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborBinaryMethodA!T)
			dst = T.fromBinary(src.get!(immutable(ubyte)[]));
		else static if (isAggregateType!T && isSerializable!T && hasConvertCborBinaryMethodB!T)
			dst = T.fromRepresentation(src.get!(immutable(ubyte)[]));
		else static if (isAggregateType!T && isSerializable!T)
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
					if (!isIgnored) foreach (ref e; src._reqMap.byKeyValue)
					{
						static if (hasName!m)
							enum memberName = getName!m;
						else
							enum memberName = m.stringof;
						
						if (e.key._reqStr == memberName)
						{
							static if (hasConvBy!m && canConvFrom!(m, string))
								dst.tupleof[i] = (() @trusted => convFrom!(m, string)(e.value.get!string))();
							else static if (hasConvBy!m && canConvFrom!(m, immutable(ubyte)[]))
								dst.tupleof[i] = (() @trusted => convFrom!(m, immutable(ubyte)[])(e.value._reqBin))();
							else static if (hasConvBy!m && canConvFrom!(m, CborValue))
								(() @trusted => dst.tupleof[i] = convFrom!(m, CborValue)(e.value))();
							else
							{
								if (!deserialize(e.value, dst.tupleof[i]))
									return false;
							}
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
		else static if(__traits(compiles, dst = src.get!T))
			dst = src.get!T;
		else
			return false;
		
		return true;
	}
	/// ditto
	T deserialize(T)(in CborValue src) @safe
	{
		T ret;
		if (!deserialize(src, ret))
			return T.init;
		return ret;
	}
	///
	@safe unittest
	{
		Builder b;
		struct Foo
		{
			int x;
			string y;
		}
		static assert(isSerializable!Foo);
		auto v = b.deserialize!Foo(b.make(["x": b.make(42), "y": b.make("foo")]));
		assert(v.x == 42);
		assert(v.y == "foo");
	}
	
	@safe unittest
	{
		Builder b;
		
		// 配列の例
		int[] intArray = [1, 2, 3, 4, 5];
		auto cborValue = b.serialize(intArray);
		assert(cborValue.type == CborType.array);
		assert(cborValue.get!(int[]) == intArray);
		assert(b.deserialize!(int[])(cborValue) == intArray);
		
		// 連想配列の例
		string[int] associativeArray = [1: "one", 2: "two", 3: "three"];
		cborValue = b.serialize(associativeArray);
		assert(cborValue.type == CborType.map);
		assert(cborValue.get!(string[int]) == associativeArray);
		assert(b.deserialize!(string[int])(cborValue) == associativeArray);
		
		// SumTypeの例
		@kind("test1") struct TestST1 { int x; string y; }
		@kind("test2") struct TestST2 { int x; string y; }
		alias ST1 = SumType!(TestST1, TestST2);
		ST1 testSumType1 = TestST1(42, "foo");
		cborValue = b.serialize(testSumType1);
		assert(cborValue.type == CborType.map);
		assert(cborValue.getValue!string("$type") == "test1");
		assert(cborValue.getValue!uint("x") == 42);
		assert(cborValue.getValue!string("y") == "foo");
		assert(b.deserialize!ST1(cborValue) == testSumType1);
		
		alias ST2 = SumType!(TestST1, int, string);
		ST2 testSumType2 = "foo";
		cborValue = b.serialize(testSumType2);
		assert(cborValue.get!string() == "foo");
		assert(b.deserialize!ST2(cborValue) == testSumType2);
		(() @trusted => testSumType2 = ST2(42))();
		cborValue = b.serialize(testSumType2);
		assert(cborValue.get!int() == 42);
		assert(b.deserialize!ST2(cborValue) == testSumType2);
		(() @trusted => testSumType2 = ST2(TestST1(100, "HogeHoge")))();
		cborValue = b.serialize(testSumType2);
		assert(cborValue.getValue!int("x") == 100);
		assert(b.deserialize!ST2(cborValue) == testSumType2);
		
		alias ST3 = SumType!(immutable(ubyte)[], int[], int[string], bool);
		static assert(isSerializableSumType!ST3);
		ST3 testSumType3 = cast(immutable ubyte[])"\x01\x02\x03";
		cborValue = b.serialize(testSumType3);
		assert(cborValue.get!(immutable(ubyte)[]) == [0x01, 0x02, 0x03]);
		assert(b.deserialize!ST3(cborValue) == testSumType3);
		(() @trusted => testSumType3 = ST3([1, 2, 3]))();
		cborValue = b.serialize(testSumType3);
		assert(cborValue.type == CborType.array);
		assert(cborValue.get!(int[]) == [1, 2, 3]);
		assert(b.deserialize!ST3(cborValue) == testSumType3);
		(() @trusted => testSumType3 = ST3(["1": 10, "2": 20, "3": 30]))();
		cborValue = b.serialize(testSumType3);
		assert(cborValue.type == CborType.map);
		assert(cborValue.get!(int[string]) == ["1": 10, "2": 20, "3": 30]);
		assert(b.deserialize!ST3(cborValue) == testSumType3);
		(() @trusted => testSumType3 = ST3(true))();
		cborValue = b.serialize(testSumType3);
		assert(cborValue.type == CborType.boolean);
		assert(cborValue.get!bool == true);
		assert(b.deserialize!ST3(cborValue) == testSumType3);
		
		// toCbor/fromCborメソッドを持つ構造体の例1
		static struct Test1
		{
			Builder b;
			int x;
			string y;
			CborValue toCbor() => b.make(["x": b.make(x), "y": b.make(y)]);
			static Test1 fromCbor(in CborValue cbor)
				=> Test1(Builder.init, cbor.getValue!int("x"), cbor.getValue!string("y"));
		}
		static assert(hasConvertCborMethodB!Test1);
		Test1 test1 = Test1(b, 42, "foo");
		cborValue = b.serialize(test1);
		assert(cborValue.type == CborType.map);
		assert(b.deserialize!Test1(cborValue) == test1);
		
		// toCbor/fromCborメソッドを持つ構造体の例2
		static struct Test2
		{
			int x;
			string y;
			CborValue toCbor(ref Builder b) const => b.make(["x": b.make(x), "y": b.make(y)]);
			static Test2 fromCbor(in CborValue cbor)
				=> Test2(cbor.getValue!int("x"), cbor.getValue!string("y"));
		}
		static assert(hasConvertCborMethodA!Test2);
		Test2 test2 = Test2(42, "foo");
		cborValue = b.serialize(test2);
		assert(cborValue.type == CborType.map);
		assert(b.deserialize!Test2(cborValue) == test2);
		
		// toBinary/fromBinaryメソッドを持つ構造体の例
		static struct Test3
		{
			int x;
			string y;
			immutable(ubyte)[] toBinary() @safe
			{
				auto app = appender!(immutable ubyte[]);
				app.put(cast(ubyte)x);
				app.put(cast(immutable ubyte[])y);
				return app.data;
			}
			static Test3 fromBinary(immutable(ubyte)[] bin) => Test3(bin[0], cast(string)bin[1 .. $]);
		}
		Test3 test3 = Test3(42, "foo");
		cborValue = b.serialize(test3);
		assert(cborValue.type == CborType.binary);
		assert(b.deserialize!Test3(cborValue) == test3);
		
		// toRepresentationメソッドを持つ構造体の例
		static struct Test4
		{
			int x;
			string y;
			immutable(ubyte)[] toRepresentation() @safe
			{
				auto app = appender!(immutable ubyte[]);
				app.put(cast(ubyte)x);
				app.put(cast(immutable ubyte[])y);
				return app.data;
			}
			static Test4 fromRepresentation(immutable(ubyte)[] rep) => Test4(rep[0], cast(string)rep[1 .. $]);
		}
		Test4 test4 = Test4(42, "foo");
		cborValue = b.serialize(test4);
		assert(cborValue.type == CborType.binary);
		assert(b.deserialize!Test4(cborValue) == test4);
		
		// ネストした構造体の例
		static struct Test5
		{
			int x;
			string y;
			Test2 z;
		}
		Test5 test5 = Test5(42, "foo");
		cborValue = b.serialize(test5);
		assert(cborValue.type == CborType.map);
		assert(b.deserialize!Test5(cborValue) == test5);
		
		import std.datetime, std.uuid;
		// converter付きのメンバの例
		static struct Test6
		{
			int x;
			@converterSysTime SysTime time;
			@converter!SysTime((immutable(ubyte)[] src) => SysTime.fromISOExtString(cast(string)src),
			                   (in SysTime src)         => cast(immutable(ubyte)[])src.toISOExtString())
			SysTime time2;
			@converter!SysTime((in CborValue src, ref SysTime dst) { dst = SysTime.fromISOExtString(src.get!string); },
			                   (in SysTime src, ref CborValue dst) { dst = src.toISOExtString(); })
			SysTime time3;
			@converterUUID      UUID uuid;
			@converterDateTime  DateTime datetime1;
			@converterDate      Date date1;
			@converterTimeOfDay TimeOfDay tod1;
			@converterDuration  Duration dur1;
		}
		static assert(hasConvBy!(Test6.time));
		static assert(canConvFrom!(Test6.time, string));
		static assert(canConvTo!(Test6.time, string));
		Test6 test6 = Test6(
			42,
			SysTime(DateTime(1999, 12, 31)),
			SysTime(DateTime(2020, 1, 1, 11, 12, 13)),
			SysTime(DateTime(2021, 2, 2, 1, 2, 3)),
			UUID("00010002-0001-0002-0003-000400050006"),
			DateTime(2022, 3, 3, 4, 5, 6),
			Date(2022, 4, 4),
			TimeOfDay(6, 7, 8),
			1234.msecs);
		cborValue = b.serialize(test6);
		assert(cborValue.type == CborType.map);
		assert(cborValue.getValue!int("x") == 42);
		assert(cborValue.getValue!string("time") == "1999-12-31T00:00:00");
		assert(cborValue.getValue!(immutable(ubyte)[])("time2") == cast(immutable(ubyte)[])"2020-01-01T11:12:13");
		assert(cborValue.getValue!string("time3") == "2021-02-02T01:02:03");
		assert(cborValue.getValue!string("uuid") == "00010002-0001-0002-0003-000400050006");
		assert(cborValue.getValue!string("datetime1") == "2022-03-03T04:05:06");
		assert(cborValue.getValue!string("date1") == "2022-04-04");
		assert(cborValue.getValue!string("tod1") == "06:07:08");
		assert(cborValue.getValue!long("dur1") == 1234.msecs.total!"hnsecs");
		assert(b.deserialize!Test6(cborValue) == test6);
	}
	
}

/*******************************************************************************
 * CBOR data type
 */
alias CborValue = Builder.CborValue;
/// ditto
alias CborType  = Builder.CborValue.Type;

/*******************************************************************************
 * CBOR builder
 */
alias CBOR = Builder;
/// ditto
alias CborBuilder = Builder;


/*******************************************************************************
 * Perse CBOR data
 */
CborValue parseCBOR(immutable(ubyte)[] binary) @trusted
{
	static Builder builder;
	return builder.parse(binary);
}

/*******************************************************************************
 * Perse CBOR data
 */
immutable(ubyte)[] toCBOR(CborValue cv) @trusted
{
	return cv._builder.build(cv);
}

// Test of the CBOR builder
@safe unittest
{
	import voile.misc: get;
	Builder builder;
	Builder.CborValue value;
	
	assert(value.isUndefined);
	assert(!value.isNull);
	assert(!value._builder);
	assert(&(value.builder()) is null);
	
	value = builder.undefinedValue;
	assert(value.isUndefined);
	assert(value._builder);
	assert(&(value.builder()) !is null);
	
	value = builder.emptyArray;
	assert(value.type == CborType.array);
	assert(!value.get!bool);
	
	value = builder.emptyMap;
	assert(value.type == CborType.map);
	assert(!value.get!bool);
	
	// Test for integer values
	value = builder.make(null);
	assert(!value.isUndefined);
	assert(value.isNull);
	
	// Test for integer values
	value = builder.make(42);
	assert(value._instance.get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)42);
	assert(!value.isUndefined);
	assert(!value.isNull);
	assert(value.get!int == 42);
	assert(value.get!uint == 42u);
	assert(value.get!ubyte == 42u);
	assert(value.get!long == 42);
	assert(value.get!float == 42.0f);
	assert(value.get!double == 42.0);
	assert(value.get!real == 42.0);
	assert(value.get!string == "42");
	
	// Test for unsigned integer values
	value = builder.make(42u);
	assert(value._instance.get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)42);
	assert(!value.isUndefined);
	assert(!value.isNull);
	assert(value.get!int == 42);
	assert(value.get!uint == 42u);
	assert(value.get!float == 42.0f);
	assert(value.get!string == "42");
	
	// Test for negative integer values
	value = builder.make(-42);
	assert(value._instance.get!(Builder.NegativeInteger) == cast(Builder.NegativeInteger)41);
	assert(!value.isUndefined);
	assert(!value.isNull);
	assert(value.get!int == -42);
	assert(value.get!uint == cast(uint)-42);
	assert(value.get!float == -42.0f);
	assert(value.get!string == "-42");
	
	// Integer overflow test
	value = builder.make(long.max);
	assert(value._instance.get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)long.max);
	assert(value.get!long == long.max);
	value = builder.make(ulong.max);
	assert(value._instance.get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)ulong.max);
	assert(value.get!ulong == ulong.max);
	value = builder.make(long.min);
	assert(value._instance.get!(Builder.NegativeInteger) == cast(Builder.NegativeInteger)0x7FFFFFFFFFFFFFFF);
	assert(value.get!long == long.min);
	value = builder.make(cast(Builder.NegativeInteger)0xCFFFFFFFFFFFFFFF);
	assert(value._instance.get!(Builder.NegativeInteger) == cast(Builder.NegativeInteger)0xCFFFFFFFFFFFFFFF);
	assert(value.isOverflowedInteger);
	assert(value.get!ulong == ulong(0x3000000000000000));
	
	// Test for boolean values
	value = builder.make(true);
	assert(value._instance.get!(Builder.Boolean) == cast(Builder.Boolean)true);
	assert(value.get!bool);
	assert(value.get!string == "true");
	
	// Test for float values
	value = builder.make(3.14f);
	assert(value._instance.get!(Builder.SingleFloat) == cast(Builder.SingleFloat)3.14f);
	
	// Test for double values
	value = builder.make(3.14);
	assert(value._instance.get!(Builder.DoubleFloat) == cast(Builder.DoubleFloat)3.14);
	
	// Test for string values
	value = builder.make("hello");
	assert(value._instance.get!(Builder.String) == cast(Builder.String)"hello");
	assert(value.get!string == "hello");
	
	// Test for binary values
	value = builder.make(cast(immutable(ubyte)[])"\x01\x02\x03"c);
	assert(value._instance.get!(Builder.Binary) == cast(Builder.Binary)"\x01\x02\x03"c);
	
	// Test for array values
	value = builder.make([1, 2, 3]);
	auto cborArray = value._instance.get!(Builder.CborValue.CborArray);
	assert(cborArray.length == 3);
	assert(cborArray[0].get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)1);
	assert(cborArray[1].get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)2);
	assert(cborArray[2].get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)3);
	
	// Test for associative array values
	value = builder.make(["1_one": 1, "2_two": 2]);
	auto cborMap = value._reqMap;
	assert(cborMap.items.length == 2);
	assert(cborMap.items[0].key.get!(Builder.String) == cast(Builder.String)"1_one");
	assert(cborMap.items[0].value._instance.get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)1);
	assert(cborMap.items[1].key.get!(Builder.String) == cast(Builder.String)"2_two");
	assert(cborMap.items[1].value._instance.get!(Builder.PositiveInteger) == cast(Builder.PositiveInteger)2);
	assert(value.getValue("1_one", 0) == 1);
	assert(value.getValue("2_two", 0) == 2);
	assert(value.getValue("3_three", 333) == 333);
	assert(value.getValue("4_four", imported!"std.exception".enforce(0)) == 0);
	
	// Test for cbor values
	value = builder.make(cast(Builder.String)"aaa");
	assert(value._instance.get!(Builder.String) == cast(Builder.String)"aaa");
}

// Test of the CBOR parser
@safe unittest
{
	import std.conv: to;
	import std.math: isClose;
	Builder builder;
	Builder.CborValue value;
	
	// Test parsing of integer values
	ubyte[] data = [0x18, 0x2A]; // 42
	value = builder.parse(data);
	assert(value.type == CborType.positive);
	assert(value.get!int == 42);
	assert(builder.build(value) == [0x18, 0x2A]);
	
	// Test parsing of boolean values
	data = [0xF5]; // True
	value = builder.parse(data);
	assert(value.type == CborType.boolean);
	assert(value.get!bool == true);
	assert(builder.build(value) == [0xF5]);
	data = [0xF4]; // False
	value = builder.parse(data);
	assert(value.get!bool == false);
	assert(builder.build(value) == [0xF4]);
	
	// Test parsing of Null
	data = [0xF6];
	value = builder.parse(data);
	assert(value.type == CborType.nullValue);
	assert(value.isNull);
	assert(builder.build(value) == [0xF6]);
	
	// Test parsing of Undefined
	data = [0xF7];
	value = builder.parse(data);
	assert(value.type == CborType.undefined);
	assert(value.isUndefined);
	assert(builder.build(value) == [0xF7]);
	
	// Test parsing of long integer values
	data = [0x1B, 0x00, 0x00, 0x00, 0x1C, 0xBE, 0x99, 0x1A, 0x14];
	value = builder.parse(data);
	assert(value.type == CborType.positive);
	assert(value.get!long == 123_456_789_012);
	assert(builder.build(value) == [0x1B, 0x00, 0x00, 0x00, 0x1C, 0xBE, 0x99, 0x1A, 0x14]);
	
	// Test parsing of binary values
	data = [0x42, 0x01, 0x02]; // [0x01, 0x02]
	value = builder.parse(data);
	assert(value.type == CborType.binary);
	assert(value.get!(immutable(ubyte)[]) == [0x01, 0x02]);
	assert(builder.build(value) == [0x42, 0x01, 0x02]);
	
	// Test parsing of string values
	data = [0x63, 'f', 'o', 'o']; // "foo"
	value = builder.parse(data);
	assert(value.type == CborType.string);
	assert(value.get!string == "foo");
	assert(builder.build(value) == [0x63, 'f', 'o', 'o']);
	
	// Test parsing of array values
	data = [0x83, 0x01, 0x02, 0x03]; // [1, 2, 3]
	value = builder.parse(data);
	assert(value.type == CborType.array);
	auto cborArray = value.get!(CborValue.CborArray);
	assert(cborArray.length == 3);
	assert(cborArray[0].get!int == 1);
	assert(cborArray[1].get!int == 2);
	assert(cborArray[2].get!int == 3);
	assert(builder.build(value) == [0x83, 0x01, 0x02, 0x03]);
	
	// Test parsing of map values
	data = [0xA2, 0x61, 'a', 0x01, 0x61, 'b', 0x02]; // {"a": 1, "b": 2}
	value = builder.parse(data);
	auto cborMap = value._reqMap;
	assert(value.type == CborType.map);
	assert(cborMap.items.length == 2);
	assert(cborMap.items[0].key.get!string == "a");
	assert(cborMap.items[0].value.get!int == 1);
	assert(cborMap.items[1].key.get!string == "b");
	assert(cborMap.items[1].value.get!int == 2);
	assert(builder.build(value) == [0xA2, 0x61, 'a', 0x01, 0x61, 'b', 0x02]);
	
	// Test parsing of 16-bit float values
	data = [0xF9, 0x3C, 0x00]; // 1.0 in 16-bit float
	value = builder.parse(data);
	assert(value.type == CborType.float16);
	assert(value.get!float == 1.0f);
	assert(builder.build(value) == [0xF9, 0x3C, 0x00]);
	
	// Test parsing of 32-bit float values
	data = [0xFA, 0x40, 0x49, 0x0F, 0xDB]; // 3.1415927 in 32-bit float
	value = builder.parse(data);
	assert(value.type == CborType.float32);
	assert(value.get!float.isClose(3.1415927f, 1e-6f));
	assert(builder.build(value) == [0xFA, 0x40, 0x49, 0x0F, 0xDB]);
	
	// Test parsing of 64-bit float values
	data = [0xFB, 0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18]; // 3.141592653589793 in 64-bit float
	value = builder.parse(data);
	assert(value.type == CborType.float64);
	assert(value.get!double.isClose(3.141592653589793, 1e-12, 0));
	assert(builder.build(value) == [0xFB, 0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18]);
	
	// Test parsing of negative integer values
	data = [0x20]; // -1
	value = builder.parse(data);
	assert(value.type == CborType.negative);
	assert(value.get!int == -1);
	assert(builder.build(value) == [0x20]);
	
	data = [0x21]; // -2
	value = builder.parse(data);
	assert(value.get!int == -2);
	assert(builder.build(value) == [0x21]);
	
	data = [0x38, 0x63]; // -100
	value = builder.parse(data);
	assert(value.get!int == -100);
	assert(builder.build(value) == [0x38, 0x63]);
	
	data = [0x39, 0x01, 0x90]; // -401
	value = builder.parse(data);
	assert(value.get!int == -401);
	assert(builder.build(value) == [0x39, 0x01, 0x90]);
	
	data = [0x3B, 0x00, 0x00, 0x00, 0x1C, 0xBE, 0x99, 0x1A, 0x13]; // -123_456_789_012
	value = builder.parse(data);
	assert(value.get!long == -123_456_789_012);
	assert(builder.build(value) == [0x3B, 0x00, 0x00, 0x00, 0x1C, 0xBE, 0x99, 0x1A, 0x13]);
}
