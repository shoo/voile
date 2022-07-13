/*******************************************************************************
 * Binary data serializer/deserializer
 */
module voile.bindat;

import std.range, std.traits;
import voile.munion;
public import voile.attr;

private enum Endian
{
	little, big
}

/*******************************************************************************
 * リトルエンディアンのデータに付与するUDA
 */
enum littleEndian = Endian.little;

/*******************************************************************************
 * ビッグエンディアンのデータに付与するUDA
 */
enum bigEndian = Endian.big;

version (LittleEndian)
{
	/***************************************************************************
	 * システムのエンディアンがリトルかビッグかで切り替えが行われるUDA
	 */
	enum systemEndian = littleEndian;
}
else
{
	/***************************************************************************
	 * システムのエンディアンがリトルかビッグかで切り替えが行われるUDA
	 */
	enum systemEndian = bigEndian;
}


private template getEndian(alias val)
{
	static if (hasUDA!(val, Endian))
	{
		enum getEndian = getUDAs!(val, Endian)[$-1];
	}
	else
	{
		enum getEndian = systemEndian;
	}
}

@safe unittest
{
	struct A
	{
		@littleEndian ushort a;
		@bigEndian ulong b;
		uint c;
	}
	static assert(getEndian!(A.a) == littleEndian);
	static assert(getEndian!(A.b) == bigEndian);
	static assert(getEndian!(A.c) == systemEndian);
}

private enum isSystemEndian(alias val) = getEndian!val == systemEndian;

@safe unittest
{
	struct A
	{
		@littleEndian ushort a;
		@bigEndian ulong b;
		uint c;
	}
	version (LittleEndian)
	{
		static assert( isSystemEndian!(A.a));
		static assert(!isSystemEndian!(A.b));
		static assert( isSystemEndian!(A.c));
	}
	version (BigEndian)
	{
		static assert(!isSystemEndian!(A.a));
		static assert( isSystemEndian!(A.b));
		static assert( isSystemEndian!(A.c));
	}
}

/*******************************************************************************
 * バイトの並びを逆順にする
 * 
 * LittleEndianをBigEndianに、あるいはその逆を行うことができる
 */
private void swapBytes(T)(in T src, out T dst) @trusted
{
	static if (T.sizeof == 1)
	{
		dst = src;
	}
	else static if (T.sizeof == 2)
	{
		import core.bitop;
		ushort tmp = byteswap(*cast(ushort*)&src);
		dst = *cast(T*)&tmp;
	}
	else static if (T.sizeof == 4)
	{
		import core.bitop;
		uint tmp = bswap(*cast(uint*)&src);
		dst = *cast(T*)&tmp;
	}
	else static if (T.sizeof == 8)
	{
		import core.bitop;
		ulong tmp = bswap(*cast(ulong*)&src);
		dst = *cast(T*)&tmp;
	}
	else
	{
		static assert(0, "Unsupported type to swap byte ordering");
	}
}
/// ditto
private T swapBytes(T)(in T src)
{
	T tmp = void;
	swapBytes(src, tmp);
	return tmp;
}

private struct PreLength(T)
{
	alias LengthType = T;
}

/*******************************************************************************
 * 配列の長さがバイナリの前方に現れる場合のUDA
 */
template preLength(T)
{
	alias preLength = PreLength!T;
}

private struct ArrayLength
{
	string predication;
}

/*******************************************************************************
 * 配列の長さを計算によって行うUDA
 */
template arrayLength(string pred)
{
	enum arrayLength = ArrayLength(pred);
}
/// ditto
ArrayLength arrayLength()(string pred)
{
	return ArrayLength(pred);
}

private enum hasPreLength(alias val) = hasUDA!(val, PreLength);
private enum hasArrayLength(alias val) = hasUDA!(val, ArrayLength);
private enum getArrayLengthPred(alias val) = getUDAs!(val, ArrayLength)[0].predication;
private template getLengthType(alias val)
{
	static if (hasPreLength!(val))
	{
		alias getLengthType = TemplateArgsOf!(getUDAs!(val, PreLength))[0];
	}
	else static if (hasArrayLength!(val))
	{
		alias getLengthType = typeof( (){
			alias Parent = __traits(parent, val);
			Parent tmp;
			with (tmp)
				return mixin(getArrayLengthPred!(val));
		}());
	}
	else static assert(0, "Unknown length type");
}

@safe unittest
{
	struct A
	{
		@preLength!ushort ubyte[] data;
	}
	A a;
	static assert(hasPreLength!(a.data));
	static assert(is(getLengthType!(a.data) == ushort));
	
	
	struct B
	{
		uint length;
		@arrayLength("length") ubyte[] data;
	}
	B b;
	static assert(hasArrayLength!(b.data));
	static assert(is(getLengthType!(b.data) == uint));
}


/*******************************************************************************
 * 入力対象のバイナリデータ型
 */
enum bool isInputBinary(InputRange) = isInputRange!InputRange && is(Unqual!(ForeachType!InputRange) == ubyte);

/*******************************************************************************
 * 出力対象のバイナリデータ型
 */
enum bool isOutputBinary(OutputRange) = isOutputRange!(OutputRange, ubyte);

/*******************************************************************************
 * 基本型要素をもつ配列
 */
template isBasicArray(T)
{
	static if (isArray!T)
		enum bool isBasicArray = isBasicType!(ForeachType!T);
	else
		enum bool isBasicArray = false;
}

/*******************************************************************************
 * Proxy
 * 
 * 1. 以下の関数を持つ
 *    - `void writeBinary(InputRange)(ref InputRange) const;`
 *    - `void readBinary(OutputRange)(ref OutputRange);`
 * 2. 【未実装】以下の関数を持つ
 *    - `size_t binaryLength() const @property;`
 *    - `immutable(ubyte)[] toBinary() const;`
 *    - `void fromBinary(in byte[]);`
 * 3. 【未実装】型の宣言に以下のUDAを持つ
 *    - `@convBy!Proxy`
 *      - Proxy: `void to(OutputRange)(in T src, ref OutputRange r);`
 *      - Proxy: `void from(InputRange)(ref InputRange r, ref T dst);`
 * 4. メンバの宣言に以下のUDAを持つ
 *    - `@convBy!Proxy`
 *      - Proxy type3: `void to(OutputRange)(in T src, ref OutputRange);`
 *      - Proxy type3: `void from(InputRange)(ref InputRange, ref T dst);`
 * 5. 【未実装】メンバの宣言に以下のUDAを持つ
 *    - `@preLength!Size`
 *    - `@convBy!Proxy` : `immutable(ubyte)[]`
 * 6. 【未実装】メンバの宣言に以下のUDAを持つ
 *    - `@arrayLength!"..."`
 *    - `@convBy!Proxy` : `immutable(ubyte)[]`
 */
template hasBinaryConvertionProxy(T)
{
	alias InputRange = InputRangeObject!(ubyte[]);
	alias OutputRange = OutputRangeObject!(ubyte[], ubyte);
	static if ( is(typeof(T.init.readBinary(lvalueOf!InputRange)))
	        && !is(typeof(T.init.readBinary(rvalueOf!InputRange)))
	        &&  is(typeof(T.init.writeBinary(lvalueOf!OutputRange)))
	        && !is(typeof(T.init.writeBinary(rvalueOf!OutputRange))))
	{
		enum bool hasBinaryConvertionProxy = true;
	}
	else
	{
		enum bool hasBinaryConvertionProxy = false;
	}
}
/// ditto
template hasBinaryConvertionProxy(T, string memberName)
{
	alias InputRange = std.range.interfaces.InputRange!ubyte;
	alias OutputRange = std.range.interfaces.OutputRange!ubyte;
	alias value = __traits(getMember, T, memberName);
	static if (hasConvBy!value)
	{
		static if (canConvFrom!(value, InputRange) && canConvTo!(value, OutputRange))
		{
			enum bool hasBinaryConvertionProxy = true;
		}
		else
		{
			enum bool hasBinaryConvertionProxy = false;
		}
	}
	else
	{
		enum bool hasBinaryConvertionProxy = false;
	}
}

/*******************************************************************************
 * バイナリのシリアライズ
 */
void serializeToBinDat(Endian endian, OutputRange, T)(ref OutputRange r, in T data) @trusted
if (isOutputBinary!OutputRange && isBasicType!T)
{
	static if (endian == systemEndian)
	{
		put(r, (cast(ubyte*)&data)[0..T.sizeof]);
	}
	else
	{
		auto tmp = swapBytes(data);
		put(r, (cast(ubyte*)&tmp)[0..T.sizeof]);
	}
}
/// ditto
void serializeToBinDat(Endian endian, OutputRange, T: ubyte)(ref OutputRange r, in T data)
if (isOutputBinary!OutputRange && isBasicType!T)
{
	put(r, data);
}
/// ditto
void serializeToBinDat(OutputRange, T)(ref OutputRange r, in T data) @trusted
if (isOutputBinary!OutputRange && isBasicType!T)
{
	r.serializeToBinDat!systemEndian(data);
}
/// ditto
void serializeToBinDat(OutputRange, T: ubyte)(ref OutputRange r, in T data)
if (isOutputBinary!OutputRange && isBasicType!T)
{
	put(r, data);
}
/// ditto
void serializeToBinDat(Endian endian, OutputRange, T)(ref OutputRange r, in T data)
if (isOutputBinary!OutputRange && isBasicArray!T)
{
	static if (is(Unqual!T: const(ubyte)[]))
	{
		put(r, data[]);
	}
	else
	{
		foreach (ref e; data)
			r.serializeToBinDat!endian(e);
	}
}
/// ditto
void serializeToBinDat(OutputRange, T)(ref OutputRange r, in T data)
if (isOutputBinary!OutputRange && isArray!T)
{
	static if (isBasicArray!T)
	{
		r.serializeToBinDat!systemEndian(data);
	}
	else
	{
		foreach (ref e; data)
			r.serializeToBinDat(e);
	}
}
/// ditto
void serializeToBinDat(OutputRange, T)(ref OutputRange r, in T data)
if (isOutputBinary!OutputRange && is(T == struct))
{
	static if (hasBinaryConvertionProxy!T)
	{
		//----------------------------------
		// Proxy
		//----------------------------------
		data.writeBinary(r);
	}
	else static foreach (memberIdx, memberName; FieldNameTuple!T)
	{{
		alias memberValue = __traits(getMember, data, memberName);
		alias memberType  = typeof(memberValue);
		static if (hasBinaryConvertionProxy!(T, memberName) && canConvTo!(memberValue, OutputRange))
		{
			convertTo!memberValue(__traits(getMember, data, memberName), r);
		}
		else static if (isBasicType!memberType)
		{
			//----------------------------------
			// 基本型
			//----------------------------------
			r.serializeToBinDat!(getEndian!memberValue)(__traits(getMember, data, memberName));
		}
		else static if (isDynamicArray!memberType)
		{
			//----------------------------------
			// 動的配列
			//----------------------------------
			// 長さの書き込み
			static if (hasPreLength!memberValue)
				r.serializeToBinDat!(getEndian!memberValue)(
					cast(getLengthType!memberValue)__traits(getMember, data, memberName).length);
			// データの書き込み
			static if (isBasicArray!memberType)
			{
				r.serializeToBinDat!(getEndian!memberValue)(__traits(getMember, data, memberName));
			}
			else
			{
				r.serializeToBinDat(__traits(getMember, data, memberName));
			}
		}
		else static if (isStaticArray!memberType)
		{
			//----------------------------------
			// 静的配列
			//----------------------------------
			// データの書き込み
			static if (isBasicArray!memberType)
			{
				r.serializeToBinDat!(getEndian!memberValue)(__traits(getMember, data, memberName));
			}
			else
			{
				r.serializeToBinDat(__traits(getMember, data, memberName));
			}
		}
		else
		{
			// その他は再帰
			r.serializeToBinDat(__traits(getMember, data, memberName));
		}
	}}
}
/// ditto
void serializeToBinDat(OutputRange, T: Endata!U, U)(ref OutputRange r, in T data)
if (isOutputBinary!OutputRange && is(T == struct))
{
	alias Tag = TagType!T;
	static if (is(Tag EnumBaseType == enum))
		alias TagBaseType = EnumBaseType;
	else static assert(0);
	
	// タグの記録
	static if (isSystemEndian!Tag)
	{
		r.serializeToBinDat(data.tag);
	}
	else
	{
		r.serializeToBinDat(swapBytes(data.tag));
	}
	// データ内容の記録
	switch (data.tag)
	{
		static foreach (tag; memberTags!T)
		{
		case tag:
			import std.conv;
			static if (isBasicType!(TypeFromTag!(T, tag)))
			{
				enum tagName = tag.to!string;
				enum endian  = getEndian!(__traits(getMember, Tag, tagName));
				r.serializeToBinDat!endian(data.get!tag());
			}
			else
			{
				r.serializeToBinDat(data.get!tag());
			}
			return;
		}
		default:
			break;
	}
}
/// ditto
immutable(ubyte)[] serializeToBinDat(T)(in T data) @trusted
{
	import std.array;
	auto app = appender!(ubyte[]);
	app.serializeToBinDat(data);
	return cast(immutable)app.data;
}
/// ditto
immutable(ubyte)[] serializeToBinDat(Endian endian, T)(in T data) @trusted
if (isBasicType!T || isArray!T)
{
	import std.array;
	auto app = appender!(ubyte[]);
	app.serializeToBinDat!endian(data);
	return cast(immutable)app.data;
}

/// 基本型と列挙値
@safe unittest
{
	ubyte a = 10;
	assert(a.serializeToBinDat!littleEndian() == [10]);
	uint b = 10;
	assert(b.serializeToBinDat!bigEndian() == [0, 0, 0, 10]);
	
	version (LittleEndian)
		assert(b.serializeToBinDat() == [10, 0, 0, 0]);
	version (BigEndian)
		assert(b.serializeToBinDat() == [0, 0, 0, 10]);
	
	enum E { a, b }
	E e = E.a;
	assert(e.serializeToBinDat!littleEndian() == [0, 0, 0, 0]);
	e = E.b;
	assert(e.serializeToBinDat!littleEndian() == [1, 0, 0, 0]);
	assert(e.serializeToBinDat!bigEndian()    == [0, 0, 0, 1]);
}
/// 配列
@safe unittest
{
	ubyte[] a = [10, 20];
	assert(a.serializeToBinDat!littleEndian() == [10, 20]);
	uint[] b = [10, 20];
	assert(b.serializeToBinDat!bigEndian() == [0, 0, 0, 10, 0, 0, 0, 20]);
	
	version (LittleEndian)
		assert(b.serializeToBinDat() == [10, 0, 0, 0, 20, 0, 0, 0]);
	version (BigEndian)
		assert(b.serializeToBinDat() == [0, 0, 0, 10, 0, 0, 0, 20]);
	
	uint[2] c = [1,2];
	assert(c.serializeToBinDat!littleEndian() == [1, 0, 0, 0, 2, 0, 0, 0]);
	
	ubyte[8] d = [1,2,3,4,5,6,7,8];
	assert(d.serializeToBinDat() == [1,2,3,4,5,6,7,8]);
}
/// エンディアン変換
@safe unittest
{
	struct A
	{
		@bigEndian ushort a;
		@littleEndian ushort b;
	}
	auto a = A(10, 20);
	assert(a.serializeToBinDat() == [0, 10, 20, 0]);
}
/// 構造体
@safe unittest
{
	struct A
	{
		@preLength!ushort @bigEndian ubyte[] data;
	}
	auto a = A([10, 20]);
	assert(a.serializeToBinDat() == [0, 2, 10, 20]);
	
	struct B
	{
		@bigEndian uint length;
		@arrayLength!"length" @littleEndian ushort[] data;
	}
	auto b = B(2, [10, 20]);
	assert(b.serializeToBinDat() == [0, 0, 0, 2, 10, 0, 20, 0]);
	
	struct C
	{
		A a;
		@bigEndian ushort[4] x;
		B b;
	}
	auto c = C(A([10, 20]), [1,2,3,4], B(2, [10, 20]));
	assert(c.serializeToBinDat() == [
		0, 2, 10, 20,
		0,1, 0,2, 0,3, 0,4,
		0, 0, 0, 2, 10, 0, 20, 0]);
}
/// Endata
@safe unittest
{
	@littleEndian enum A: short
	{
		@bigEndian    @data!int a,
		@littleEndian @data!short b
	}
	Endata!A a;
	a.a = 10;
	assert(a.serializeToBinDat() == [0x00, 0x00, 0x00, 0x00, 0x00, 0x0a]);
	a.b = 11;
	assert(a.serializeToBinDat() == [0x01, 0x00, 0x0b, 0x00]);
}

/// Proxy
@safe unittest
{
	struct A
	{
		int a;
		void writeBinary(OutputRange)(ref OutputRange r) const
		if (isOutputBinary!OutputRange)
		{
			put(r, cast(ubyte)(a + 100));
		}
		void readBinary(InputRange)(ref InputRange r)
		if (isInputBinary!InputRange)
		{
			a = r.front - 100;
			r.popFront();
		}
	}
	static assert(hasBinaryConvertionProxy!A);
	A a = A(-10);
	assert(a.serializeToBinDat() == [90]);
	
	import std.datetime;
	struct B
	{
		static struct Proxy
		{
			static void to(OutputRange)(in DateTime d, ref OutputRange r) @trusted
			{
				r.serializeToBinDat!bigEndian(cast(ushort)d.year);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.month);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.day);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.hour);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.minute);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.second);
			}
			static void from(InputRange)(ref InputRange r, ref DateTime d) @trusted
			{
				ushort year;
				ubyte  month;
				ubyte  day;
				ubyte  hour;
				ubyte  minute;
				ubyte  second;
				year.deserializeFromBinDat!bigEndian(r);
				month.deserializeFromBinDat!bigEndian(r);
				day.deserializeFromBinDat!bigEndian(r);
				hour.deserializeFromBinDat!bigEndian(r);
				minute.deserializeFromBinDat!bigEndian(r);
				second.deserializeFromBinDat!bigEndian(r);
				d = DateTime(year, month, day, hour, minute, second);
			}
		}
		@convBy!Proxy DateTime dt;
	}
	B b = B(DateTime(2020, 12, 25));
	assert(b.serializeToBinDat() == [0x07, 0xE4, 12, 25, 0, 0, 0]);
}

/*******************************************************************************
 * 入力レンジから所定のバイト数を消費
 */
private void consume(T, InputRange)(ref T dst, ref InputRange r) @trusted
if (isInputBinary!InputRange)
{
	import std.algorithm: copy;
	static if (is(T == ubyte[]))
	{
		copy(r.take(dst.length), dst[]);
		r = r.drop(dst.length);
	}
	else static if (isBasicArray!T)
	{
		copy(r.take(ForeachType!T.sizeof * dst.length), cast(ubyte[])dst[]);
		r = r.drop(ForeachType!T.sizeof * dst.length);
	}
	else
	{
		copy(r.take(T.sizeof), (cast(ubyte*)&dst)[0..T.sizeof]);
		r = r.drop(T.sizeof);
	}
}

/*******************************************************************************
 * バイナリのデシリアライズ
 */
void deserializeFromBinDat(Endian endian, T, InputRange)(ref T dst, ref InputRange r)
if (isInputBinary!InputRange && isBasicType!T)
{
	consume(dst, r);
	static if (endian != systemEndian)
		swapBytes(dst, dst);
}
/// ditto
void deserializeFromBinDat(T, InputRange)(ref T dst, ref InputRange r)
if (isInputBinary!InputRange && isBasicType!T)
{
	dst.deserializeFromBinDat!systemEndian(r);
}
/// ditto
void deserializeFromBinDat(Endian endian, T, InputRange)(ref T dst, ref InputRange r)
if (isInputBinary!InputRange && isBasicArray!T)
{
	consume(dst, r);
	static if (endian != systemEndian)
	{
		foreach (ref e; dst)
			swapBytes(e, e);
	}
}
/// ditto
void deserializeFromBinDat(T, InputRange)(ref T dst, ref InputRange r)
if (isInputBinary!InputRange && isArray!T)
{
	static if (isBasicArray!T)
	{
		dst.deserializeFromBinDat!systemEndian(r);
	}
	else
	{
		foreach (ref e; dst)
			e.deserializeFromBinDat(r);
	}
}
/// ditto
void deserializeFromBinDat(T, InputRange)(ref T dst, ref InputRange r)
if (isInputBinary!InputRange && is(T == struct))
{
	static if (hasBinaryConvertionProxy!T)
	{
		//----------------------------------
		// Proxy
		//----------------------------------
		dst.readBinary(r);
	}
	else static foreach (memberIdx, memberName; FieldNameTuple!T)
	{{
		alias memberValue = __traits(getMember, dst, memberName);
		alias memberType  = typeof(memberValue);
		static if (hasBinaryConvertionProxy!(T, memberName) && canConvFrom!(memberValue, InputRange))
		{
			//----------------------------------
			// Proxy
			//----------------------------------
			convertFrom!memberValue(r, __traits(getMember, dst, memberName));
		}
		else static if (isBasicType!memberType)
		{
			//----------------------------------
			// 基本型
			//----------------------------------
			__traits(getMember, dst, memberName).deserializeFromBinDat!(getEndian!memberValue)(r);
		}
		else static if (isDynamicArray!memberType)
		{
			//----------------------------------
			// 動的配列
			//----------------------------------
			// 長さの読み込み
			static if (hasPreLength!memberValue)
			{{
				alias Length = getLengthType!memberValue;
				Length len;
				len.deserializeFromBinDat!(getEndian!memberValue)(r);
				__traits(getMember, dst, memberName).length = len;
			}}
			else static if (hasArrayLength!memberValue)
			{{
				with (dst)
					__traits(getMember, dst, memberName).length = mixin(getArrayLengthPred!memberValue);
			}}
			// データの読み込み
			static if (isBasicArray!memberType)
			{
				__traits(getMember, dst, memberName).deserializeFromBinDat!(getEndian!memberValue)(r);
			}
			else
			{
				__traits(getMember, dst, memberName).deserializeFromBinDat(r);
			}
		}
		else static if (isStaticArray!memberType)
		{
			//----------------------------------
			// 静的配列
			//----------------------------------
			// データの書き込み
			static if (isBasicArray!memberType)
			{
				__traits(getMember, dst, memberName).deserializeFromBinDat!(getEndian!memberValue)(r);
			}
			else
			{
				__traits(getMember, dst, memberName).deserializeFromBinDat(r);
			}
		}
		else
		{
			// その他は再帰
			__traits(getMember, dst, memberName).deserializeFromBinDat(r);
		}
	}}
}
/// ditto
void deserializeFromBinDat(T: Endata!U, InputRange, U)(ref T dst, ref InputRange r)
if (isInputBinary!InputRange && is(T == struct))
{
	alias Tag = TagType!T;
	static if (is(Tag EnumBaseType == enum))
		alias TagBaseType = EnumBaseType;
	else static assert(0);
	
	// タグの記録
	Tag tmptag;
	tmptag.deserializeFromBinDat!(getEndian!Tag)(r);
	
	// データ内容の記録
	switch (tmptag)
	{
		static foreach (tag; memberTags!T)
		{
		case tag:
			import std.conv;
			static if (isBasicType!(TypeFromTag!(T, tag)))
			{
				enum tagName = tag.to!string;
				enum endian  = getEndian!(__traits(getMember, Tag, tagName));
				alias Type = TypeFromTag!(T, tag);
				Type tmpdat;
				tmpdat.deserializeFromBinDat!endian(r);
				dst.initialize!tag(tmpdat);
			}
			else
			{
				alias Type = TypeFromTag!(T, tag);
				Type tmpdat;
				tmpdat.deserializeFromBinDat(r);
				dst.initialize!tag(tmpdat);
			}
			return;
		}
		default:
			break;
	}
}
/// ditto
void deserializeFromBinDat(Endian endian, T, InputRange)(ref T dst, InputRange r)
if (isInputBinary!InputRange)
{
	dst.deserializeFromBinDat!endian(r);
}
/// ditto
void deserializeFromBinDat(T, InputRange)(ref T dst, InputRange r)
if (isInputBinary!InputRange)
{
	dst.deserializeFromBinDat(r);
}
/// ditto
T deserializeFromBinDat(T, InputRange)(InputRange r)
if (isInputBinary!InputRange)
{
	T ret;
	ret.deserializeFromBinDat(r);
	return ret;
}

/// 基本型と列挙値
@safe unittest
{
	//ubyte[] bin(ubyte[] dat...) { return dat; }
	template bin(args...) {
		ubyte[args.length] inst = [args[]];
		ubyte[] bin() { return inst[]; }
	}
	ubyte a;
	a.deserializeFromBinDat!littleEndian(bin!(10));
	assert(a == 10);
	
	uint b;
	b.deserializeFromBinDat!bigEndian(bin!(0, 0, 0, 10));
	assert(b == 10);
	
	version (LittleEndian)
		b.deserializeFromBinDat(bin!(10, 0, 0, 0));
	version (BigEndian)
		b.deserializeFromBinDat(bin!(0, 0, 0, 10));
	assert(b == 10);
	
	enum E { a, b }
	E e;
	e.deserializeFromBinDat!littleEndian(bin!(0, 0, 0, 0));
	assert(e == E.a);
	e.deserializeFromBinDat!littleEndian(bin!(1, 0, 0, 0));
	assert(e == E.b);
	e.deserializeFromBinDat!bigEndian(bin!(0, 0, 0, 1));
	assert(e == E.b);
}

/// 配列
@safe unittest
{
	template bin(args...) {
		ubyte[args.length] inst = [args[]];
		ubyte[] bin() { return inst[]; }
	}
	ubyte[] a = new ubyte[2];
	a.deserializeFromBinDat!littleEndian(bin!(10, 20));
	assert(a == [10, 20]);
	uint[] b = new uint[2];
	b.deserializeFromBinDat!bigEndian(bin!(0, 0, 0, 10, 0, 0, 0, 20));
	assert(b == [10, 20]);
	
	version (LittleEndian)
		b.deserializeFromBinDat(bin!(10, 0, 0, 0, 20, 0, 0, 0));
	version (BigEndian)
		b.deserializeFromBinDat(bin!(0, 0, 0, 10, 0, 0, 0, 20));
	assert(b == [10, 20]);
	
	uint[2] c;
	c.deserializeFromBinDat!littleEndian(bin!(1, 0, 0, 0, 2, 0, 0, 0));
	assert(c == [1, 2]);
	
	ubyte[8] d;
	d.deserializeFromBinDat(bin!(1, 0, 0, 0, 2, 0, 0, 0));
	assert(d == [1, 0, 0, 0, 2, 0, 0, 0]);
}

/// エンディアン変換
@safe unittest
{
	template bin(args...) {
		ubyte[args.length] inst = [args[]];
		ubyte[] bin() { return inst[]; }
	}
	struct A
	{
		@bigEndian ushort a;
		@littleEndian ushort b;
	}
	A a;
	a.deserializeFromBinDat(bin!(0, 10, 20, 0));
	assert(a == A(10, 20));
}

/// 構造体
@safe unittest
{
	template bin(args...) {
		ubyte[args.length] inst = [args[]];
		ubyte[] bin() { return inst[]; }
	}
	struct A
	{
		@preLength!ushort @bigEndian ubyte[] data;
	}
	A a;
	a.deserializeFromBinDat(bin!(0, 2, 10, 20));
	assert (a == A([10, 20]));
	
	struct B
	{
		@bigEndian uint length;
		@arrayLength!"length" @littleEndian ushort[] data;
	}
	B b;
	b.deserializeFromBinDat(bin!(0, 0, 0, 2, 10, 0, 20, 0));
	assert(b == B(2, [10, 20]));
	
	struct C
	{
		A a;
		@bigEndian ushort[4] x;
		B b;
	}
	C c;
	c.deserializeFromBinDat(bin!(
		0, 2, 10, 20,
		0,1, 0,2, 0,3, 0,4,
		0, 0, 0, 2, 10, 0, 20, 0));
	assert(c == C(A([10, 20]), [1,2,3,4], B(2, [10, 20])));
}

/// Endata
@safe unittest
{
	template bin(args...) {
		ubyte[args.length] inst = [args[]];
		ubyte[] bin() { return inst[]; }
	}
	@littleEndian enum A: short
	{
		@bigEndian    @data!int a,
		@littleEndian @data!short b
	}
	Endata!A a;
	a.deserializeFromBinDat(bin!(0x00, 0x00, 0x00, 0x00, 0x00, 0x0a));
	Endata!A tmp;
	tmp.a = 10;
	assert(a == tmp);
	
	a.deserializeFromBinDat(bin!(0x01, 0x00, 0x0b, 0x00));
	tmp.b = 11;
	assert(a == tmp);
}

/// Proxy
@safe unittest
{
	template bin(args...) {
		ubyte[args.length] inst = [args[]];
		ubyte[] bin() { return inst[]; }
	}
	struct A
	{
		int a;
		void writeBinary(OutputRange)(ref OutputRange r) const
		if (isOutputBinary!OutputRange)
		{
			put(r, cast(ubyte)(a + 100));
		}
		void readBinary(InputRange)(ref InputRange r)
		if (isInputBinary!InputRange)
		{
			a = r.front - 100;
			r.popFront();
		}
	}
	A a;
	a.deserializeFromBinDat(bin!(90));
	assert(a == A(-10));
	
	import std.datetime;
	struct B
	{
		static struct Proxy
		{
			static void to(OutputRange)(in DateTime d, ref OutputRange r) @trusted
			{
				r.serializeToBinDat!bigEndian(cast(ushort)d.year);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.month);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.day);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.hour);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.minute);
				r.serializeToBinDat!bigEndian(cast(ubyte)d.second);
			}
			static void from(InputRange)(ref InputRange r, ref DateTime d) @trusted
			{
				ushort year;
				ubyte  month;
				ubyte  day;
				ubyte  hour;
				ubyte  minute;
				ubyte  second;
				year.deserializeFromBinDat!bigEndian(r);
				month.deserializeFromBinDat!bigEndian(r);
				day.deserializeFromBinDat!bigEndian(r);
				hour.deserializeFromBinDat!bigEndian(r);
				minute.deserializeFromBinDat!bigEndian(r);
				second.deserializeFromBinDat!bigEndian(r);
				d = DateTime(year, month, day, hour, minute, second);
			}
		}
		@convBy!Proxy DateTime dt;
	}
	B b;
	b.deserializeFromBinDat(bin!(0x07, 0xE4, 12, 25, 0, 0, 0));
	assert(b == B(DateTime(2020, 12, 25)));
}

/*******************************************************************************
 * バイナリの解析
 * 
 * - [0-2] タグタイプ
 *   - if [0-2]が 0x0001
 *     - [2-4] 長さ
 *     - [4-X] ペイロード
 *   - if [0-2]が 0x0002
 *     - [2] コマンド種別
 *       - if [2] が 0x01
 *         - [3-5] 付与データ
 *       - if [2] が 0x02
 *         - (なし)
 *       - if [2] が 0x03
 *         - [3.0]     フラグ1
 *         - [3.1-3.3] フラグ2
 *         - [3.3-3.6] reserved
 *         - [3.7]     フラグ8
 */
@safe unittest
{
	import voile.munion;
	struct TypeAPayload
	{
		@bigEndian @preLength!ushort ubyte[] payload;
	}
	struct TypeBPayload
	{
		struct CommandAPayload
		{
			@bigEndian ushort payload;
		}
		struct CommandCPayload
		{
			ubyte flag1;
			ubyte flag2;
			ubyte flag7;
		}
		enum CommandType: ubyte
		{
			@data!CommandAPayload
			a = 0x0001,
			b = 0x0002,
			@data!CommandCPayload
			c = 0x0003,
		}
		@bigEndian Endata!CommandType commandType;
	}
	@bigEndian enum TagType: ushort
	{
		@data!TypeAPayload
		a = 0x0001,
		@data!TypeBPayload
		b = 0x0002,
	}
	Endata!TagType bindat;
	
	static immutable ubyte[] binary1 = [
		0x00, 0x01, // [0-2] タグタイプ
		0x00, 0x04, // [2-4] 長さ
		0x00, 0x01, 0x02, 0x03 // [4-X] ペイロード
	];
	bindat.deserializeFromBinDat(binary1[]);
	assert(bindat.tag == TagType.a);
	assert(bindat.a.payload == [0x00, 0x01, 0x02, 0x03]);
	
	static immutable ubyte[] binary2 = [
		0x00, 0x02, // [0-2] タグタイプ
		0x01, // [2] コマンド種別
		0x00, 0x01 // [3-5] 付与データ
	];
	bindat.deserializeFromBinDat(binary2[]);
	assert(bindat.tag == TagType.b);
	assert(bindat.b.commandType.tag == TypeBPayload.CommandType.a);
	assert(bindat.b.commandType.a.payload == 0x0001);
}
