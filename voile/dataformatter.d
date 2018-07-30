/*******************************************************************************
 * judgement モジュール
 * 
 * 複数の要素でチェックを行いたい場合に使用することのできる Judgement が利用可能
 * 
 * Date: September 07, 2011
 * Authors:
 *     P.Knowledge, SHOO
 * License:
 *     NYSL ( http://www.kmonos.net/nysl/ )
 * 
 */
module voile.dataformatter;


import std.traits, std.typecons, std.range, std.array, std.system;
import core.bitop;

/*******************************************************************************
 * 
 */
struct DataWriter(Range, Endian rangeEndian = Endian.littleEndian)
	if (isOutputRange!(Range, const(ubyte)[])
	||  isOutputRange!(Range, ubyte)
	||  isOutputRange!(Range, const(void)[]))
{
private:
	Range range;
public:
	
	
	///
	void put(T)(in T v)
		if (is(Unqual!T == ubyte)
		||  is(Unqual!T == char)
		||  is(Unqual!T == byte) )
	{
		static if (isOutputRange!(Range, ubyte))
		{
			.put(range, cast(ubyte)v);
		}
		else
		{
			.put(range, (&v)[0..1]);
		}
	}
	
	
	/// ditto
	void put(T)(in T v)
		if (is(Unqual!T == const(ubyte)[])
		||  is(Unqual!T == const(byte)[])
		||  is(Unqual!T == const(char)[])
		||  is(Unqual!T == const(void)[])
		//||  is(Unqual!T == shared(ubyte)[])
		//||  is(Unqual!T == shared(byte)[])
		//||  is(Unqual!T == shared(char)[])
		//||  is(Unqual!T == shared(void)[])
		||  is(Unqual!T == immutable(ubyte)[])
		||  is(Unqual!T == immutable(byte)[])
		||  is(Unqual!T == immutable(char)[])
		||  is(Unqual!T == immutable(void)[])
		//||  is(Unqual!T == shared(const ubyte)[])
		//||  is(Unqual!T == shared(const byte)[])
		//||  is(Unqual!T == shared(const char)[])
		//||  is(Unqual!T == shared(const void)[])
		||  is(Unqual!T == ubyte[])
		||  is(Unqual!T == byte[])
		||  is(Unqual!T == char[])
		||  is(Unqual!T == void[])
		)
	{
		static if (isOutputRange!(Range, ubyte[]))
		{
			.put(range, cast(ubyte[])v);
		}
		else static if (isOutputRange!(Range, void[]))
		{
			.put(range, cast(void[])v);
		}
		else static if ( is(Unqual!T == void[])
		              || is(Unqual!T == const(void)[])
		              || is(Unqual!T == immutable(void)[]) )
		{
			put!(const(ubyte)[])(cast(const(ubyte)[])v);
		}
		else
		{
			foreach (ref e; v) .put(range, e);
		}
	}
	
	
	/// ditto
	void put(T)(in T v)
		if (is(Unqual!T == ushort)
		||  is(Unqual!T == short)
		||  is(Unqual!T == wchar))
	{
		static if (rangeEndian == endian)
		{
			put!(const(ubyte)[])((cast(const(ubyte)*)&v)[0..2]);
		}
		else static if (is(Unqual!T == ushort))
		{
			const ushort x = ((v&0xff00)>>8) | ((v&0x00ff)<<8);
			put!(const(ubyte)[])((cast(const(ubyte)*)&x)[0..2]);
		}
		else
		{
			put!(const(ushort))(v);
		}
	}
	
	
	/// ditto
	void put(T)(in T v)
		if (is(Unqual!T == uint)  || is(Unqual!T == int)
		||  is(Unqual!T == float) || is(Unqual!T == ifloat)
		||  is(Unqual!T == dchar) )
	{
		static if (rangeEndian == endian)
		{
			put!(const(ubyte)[])((cast(const(ubyte)*)&v)[0..4]);
		}
		else
		{
			const x = bswap(*cast(const(uint)*)&v);
			put!(const(ubyte)[])((cast(const(ubyte)*)&x)[0..4]);
		}
	}
	
	
	/// ditto
	void put(T)(T v)
		if (is(Unqual!T == ulong) || is(Unqual!T == long)
		||  is(Unqual!T == double) || is(Unqual!T == idouble) )
	{
		
		static if (rangeEndian == endian)
		{
			put!(const(ubyte)[])((cast(const(ubyte)*)&v)[0..8]);
		}
		else
		{
			const ulong x = 
			    (cast(ulong)bswap(
			        cast(const uint)((v & 0xFFFFFFFF00000000) >> 32))) |
			    ((cast(ulong)bswap(
			        cast(const uint)(v & 0x00000000FFFFFFFF))) << 32);
			put!(const(ubyte)[])((cast(const(ubyte)*)&x)[0..8]);
		}
	}
	
	
	/// ditto
	void put(T)(in T v)
		if (is(Unqual!T U == enum) && isOutputRange!(typeof(this), OriginalType!(T)))
	{
		put!(OriginalType!(T))(cast(OriginalType!(T))v);
	}
	
	
	/// ditto
	void put(SrcRange)(ref SrcRange r)
		if (isStaticArray!(Unqual!(SrcRange)))
	{
		put!(typeof(r[]))(r[]);
	}
	
	
	///
	void put(SrcRange)(SrcRange r)
		if (isInputRange!(Unqual!(SrcRange))
		&& !is(Unqual!SrcRange == const(ubyte)[])
		&& !is(Unqual!SrcRange == const(byte)[])
		&& !is(Unqual!SrcRange == const(char)[])
		&& !is(Unqual!SrcRange == const(void)[])
		//&& !is(Unqual!SrcRange == shared(ubyte)[])
		//&& !is(Unqual!SrcRange == shared(byte)[])
		//&& !is(Unqual!SrcRange == shared(char)[])
		//&& !is(Unqual!SrcRange == shared(void)[])
		&& !is(Unqual!SrcRange == immutable(ubyte)[])
		&& !is(Unqual!SrcRange == immutable(byte)[])
		&& !is(Unqual!SrcRange == immutable(char)[])
		&& !is(Unqual!SrcRange == immutable(void)[])
		//&& !is(Unqual!SrcRange == shared(const ubyte)[])
		//&& !is(Unqual!SrcRange == shared(const byte)[])
		//&& !is(Unqual!SrcRange == shared(const char)[])
		//&& !is(Unqual!SrcRange == shared(const void)[])
		&& !is(Unqual!SrcRange == ubyte[])
		&& !is(Unqual!SrcRange == byte[])
		&& !is(Unqual!SrcRange == char[])
		&& !is(Unqual!SrcRange == void[])
		&& is(typeof( {foreach (e; r) put(e);}() )))
	{
		static if ((rangeEndian == endian) && isDynamicArray!SrcRange)
		{
			put!(const(ubyte)[])(cast(const(ubyte)[])r);
		}
		else
		{
			foreach (e; r) put(e);
		}
	}
}


///
DataWriter!(ElementType!Range[], Endian.littleEndian) leWriter(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}


/// ditto
DataWriter!(Range, Endian.littleEndian) leWriter(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}


///
DataWriter!(ElementType!Range[], Endian.bigEndian) beWriter(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}


/// ditto
DataWriter!(Range, Endian.bigEndian) beWriter(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}


@system unittest
{
	alias ob = DataWriter!(ubyte[]);
	enum E: uint { e }
	static assert(isOutputRange!(ob, ubyte));
	static assert(isOutputRange!(ob, byte));
	static assert(isOutputRange!(ob, ushort));
	static assert(isOutputRange!(ob, short));
	static assert(isOutputRange!(ob, uint));
	static assert(isOutputRange!(ob, int));
	static assert(isOutputRange!(ob, ulong));
	static assert(isOutputRange!(ob, long));
	static assert(isOutputRange!(ob, float));
	static assert(isOutputRange!(ob, double));
	static assert(isOutputRange!(ob, char));
	static assert(isOutputRange!(ob, wchar));
	static assert(isOutputRange!(ob, dchar));
	static assert(isOutputRange!(ob, E));
	static assert(isOutputRange!(ob, ubyte[]));
	static assert(isOutputRange!(ob, byte[]));
	static assert(isOutputRange!(ob, ushort[]));
	static assert(isOutputRange!(ob, short[]));
	static assert(isOutputRange!(ob, uint[]));
	static assert(isOutputRange!(ob, int[]));
	static assert(isOutputRange!(ob, ulong[]));
	static assert(isOutputRange!(ob, long[]));
	static assert(isOutputRange!(ob, float[]));
	static assert(isOutputRange!(ob, double[]));
	static assert(isOutputRange!(ob, char[]));
	static assert(isOutputRange!(ob, wchar[]));
	static assert(isOutputRange!(ob, dchar[]));
	static assert(isOutputRange!(ob, E[]));
	static assert(isOutputRange!(ob, const ubyte));
	static assert(isOutputRange!(ob, const byte));
	static assert(isOutputRange!(ob, const ushort));
	static assert(isOutputRange!(ob, const short));
	static assert(isOutputRange!(ob, const uint));
	static assert(isOutputRange!(ob, const int));
	static assert(isOutputRange!(ob, const ulong));
	static assert(isOutputRange!(ob, const long));
	static assert(isOutputRange!(ob, const float));
	static assert(isOutputRange!(ob, const double));
	static assert(isOutputRange!(ob, const char));
	static assert(isOutputRange!(ob, const wchar));
	static assert(isOutputRange!(ob, const dchar));
	static assert(isOutputRange!(ob, const E));
	static assert(isOutputRange!(ob, const ubyte[]));
	static assert(isOutputRange!(ob, const byte[]));
	static assert(isOutputRange!(ob, const ushort[]));
	static assert(isOutputRange!(ob, const short[]));
	static assert(isOutputRange!(ob, const uint[]));
	static assert(isOutputRange!(ob, const int[]));
	static assert(isOutputRange!(ob, const ulong[]));
	static assert(isOutputRange!(ob, const long[]));
	static assert(isOutputRange!(ob, const float[]));
	static assert(isOutputRange!(ob, const double[]));
	static assert(isOutputRange!(ob, const char[]));
	static assert(isOutputRange!(ob, const wchar[]));
	static assert(isOutputRange!(ob, const dchar[]));
	static assert(isOutputRange!(ob, const E[]));
	// static assert(isOutputRange!(ob, shared ubyte));
	// static assert(isOutputRange!(ob, shared byte));
	// static assert(isOutputRange!(ob, shared ushort));
	// static assert(isOutputRange!(ob, shared short));
	// static assert(isOutputRange!(ob, shared uint));
	// static assert(isOutputRange!(ob, shared int));
	// static assert(isOutputRange!(ob, shared ulong));
	// static assert(isOutputRange!(ob, shared long));
	// static assert(isOutputRange!(ob, shared float));
	// static assert(isOutputRange!(ob, shared double));
	// static assert(isOutputRange!(ob, shared char));
	// static assert(isOutputRange!(ob, shared wchar));
	// static assert(isOutputRange!(ob, shared dchar));
	// static assert(isOutputRange!(ob, shared E));
	// static assert(isOutputRange!(ob, shared ubyte[]));
	// static assert(isOutputRange!(ob, shared byte[]));
	// static assert(isOutputRange!(ob, shared ushort[]));
	// static assert(isOutputRange!(ob, shared short[]));
	// static assert(isOutputRange!(ob, shared uint[]));
	// static assert(isOutputRange!(ob, shared int[]));
	// static assert(isOutputRange!(ob, shared ulong[]));
	// static assert(isOutputRange!(ob, shared long[]));
	// static assert(isOutputRange!(ob, shared float[]));
	// static assert(isOutputRange!(ob, shared double[]));
	// static assert(isOutputRange!(ob, shared char[]));
	// static assert(isOutputRange!(ob, shared wchar[]));
	// static assert(isOutputRange!(ob, shared dchar[]));
	// static assert(isOutputRange!(ob, shared E[]));
	// static assert(isOutputRange!(ob, shared(const(ubyte))));
	// static assert(isOutputRange!(ob, shared(const(byte))));
	// static assert(isOutputRange!(ob, shared(const(ushort))));
	// static assert(isOutputRange!(ob, shared(const(short))));
	// static assert(isOutputRange!(ob, shared(const(uint))));
	// static assert(isOutputRange!(ob, shared(const(int))));
	// static assert(isOutputRange!(ob, shared(const(ulong))));
	// static assert(isOutputRange!(ob, shared(const(long))));
	// static assert(isOutputRange!(ob, shared(const(float))));
	// static assert(isOutputRange!(ob, shared(const(double))));
	// static assert(isOutputRange!(ob, shared(const(char))));
	// static assert(isOutputRange!(ob, shared(const(wchar))));
	// static assert(isOutputRange!(ob, shared(const(dchar))));
	// static assert(isOutputRange!(ob, shared(const(E))));
	// static assert(isOutputRange!(ob, shared(const(ubyte[]))));
	// static assert(isOutputRange!(ob, shared(const(byte[]))));
	// static assert(isOutputRange!(ob, shared(const(ushort[]))));
	// static assert(isOutputRange!(ob, shared(const(short[]))));
	// static assert(isOutputRange!(ob, shared(const(uint[]))));
	// static assert(isOutputRange!(ob, shared(const(int[]))));
	// static assert(isOutputRange!(ob, shared(const(ulong[]))));
	// static assert(isOutputRange!(ob, shared(const(long[]))));
	// static assert(isOutputRange!(ob, shared(const(float[]))));
	// static assert(isOutputRange!(ob, shared(const(double[]))));
	static assert(isOutputRange!(ob, immutable ubyte));
	static assert(isOutputRange!(ob, immutable byte));
	static assert(isOutputRange!(ob, immutable ushort));
	static assert(isOutputRange!(ob, immutable short));
	static assert(isOutputRange!(ob, immutable uint));
	static assert(isOutputRange!(ob, immutable int));
	static assert(isOutputRange!(ob, immutable ulong));
	static assert(isOutputRange!(ob, immutable long));
	static assert(isOutputRange!(ob, immutable float));
	static assert(isOutputRange!(ob, immutable double));
	static assert(isOutputRange!(ob, immutable E));
	static assert(isOutputRange!(ob, immutable ubyte[]));
	static assert(isOutputRange!(ob, immutable byte[]));
	static assert(isOutputRange!(ob, immutable ushort[]));
	static assert(isOutputRange!(ob, immutable short[]));
	static assert(isOutputRange!(ob, immutable uint[]));
	static assert(isOutputRange!(ob, immutable int[]));
	static assert(isOutputRange!(ob, immutable ulong[]));
	static assert(isOutputRange!(ob, immutable long[]));
	static assert(isOutputRange!(ob, immutable float[]));
	static assert(isOutputRange!(ob, immutable double[]));
	static assert(isOutputRange!(ob, immutable char[]));
	static assert(isOutputRange!(ob, immutable wchar[]));
	static assert(isOutputRange!(ob, immutable dchar[]));
	static assert(isOutputRange!(ob, immutable E[]));
	static assert(isOutputRange!(ob, string));
	static assert(isOutputRange!(ob, wstring));
	static assert(isOutputRange!(ob, dstring));
	static assert(isOutputRange!(ob, const string));
	static assert(isOutputRange!(ob, immutable wstring));
	
	ubyte[16] obuf1;
	ubyte[16] obuf2;
	{
		ushort[8] ibuf = [1,2,3,4,5,6,7,8];
		auto rl = leWriter(obuf1);
		auto rb = beWriter(obuf2);
		rl.put(ibuf);
		rb.put(ibuf);
		assert(obuf1[] != obuf2[]);
		assert(obuf1[0..16] == [1,0,2,0,3,0,4,0,5,0,6,0,7,0,8,0]);
		assert(obuf2[0..16] == [0,1,0,2,0,3,0,4,0,5,0,6,0,7,0,8]);
	}
	{
		uint[4] ibuf = [1,2,3,4];
		auto rl = leWriter(obuf1);
		auto rb = beWriter(obuf2);
		rl.put(ibuf);
		rb.put(ibuf);
		assert(obuf1[0..16] == [1,0,0,0,2,0,0,0,3,0,0,0,4,0,0,0]);
		assert(obuf2[0..16] == [0,0,0,1,0,0,0,2,0,0,0,3,0,0,0,4]);
	}
	{
		ulong[2] ibuf = [1,2];
		auto rl = leWriter(obuf1);
		auto rb = beWriter(obuf2);
		rl.put(ibuf);
		rb.put(ibuf);
		assert(obuf1[] != obuf2[]);
		assert(obuf1[0..16] == [1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0]);
		assert(obuf2[0..16] == [0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,2]);
	}
	{
		float[4] ibuf = [1,2,3,4];
		auto rl = leWriter(obuf1);
		auto rb = beWriter(obuf2);
		rl.put(ibuf);
		rb.put(ibuf);
		assert(obuf1[] != obuf2[]);
		assert(cast(typeof(ibuf[]))obuf1[0..16] == ibuf[]);
	}
}



///
void pick(R, E)(R r, ref E e)
	if (!isArray!E)
{
	static if (hasMember!(R, "pick") ||
		(isPointer!R && is(pointerTarget!R == struct) &&
		 hasMember!(pointerTarget!R, "pick")))
	{
		// commit to using the "pick" method
		static if (!isArray!R && is(typeof(r.pick(e))))
		{
			r.pick(e);
		}
		else static if (!isArray!R && is(typeof(r.pick((&e)[0..1]))))
		{
			r.pick((&e)[0..1]);
		}
		else
		{
			static assert(false,
				"Cannot pick a "~R.stringof~" into a "~E.stringof);
		}
	}
	else
	{
		static if (isInputRange!R)
		{
			// Commit to using assignment to front
			static if (is(typeof(e = r.front, r.popFront())))
			{
				e = r.front;
				r.popFront();
			}
			else static if (isInputRange!E && is(typeof(pick(r, e.front))))
			{
				for (; !e.empty; e.popFront()) pick(r, e.front);
			}
			else
			{
				static assert(false,
						"Cannot pick a "~E.stringof~" into a "~R.stringof);
			}
		}
		else
		{
			// Commit to using opCall
			static if (is(typeof(r(e))))
			{
				r(e);
			}
			else static if (is(typeof(r((&e)[0..1]))))
			{
				r((&e)[0..1]);
			}
			else
			{
				static assert(false,
						"Cannot pick a "~E.stringof~" into a "~R.stringof);
			}
		}
	}
}


/// ditto
void pick(R, E)(ref R r, E e)
	if (isDynamicArray!E)
{
	static if (hasMember!(R, "pick") ||
		(isPointer!R && is(pointerTarget!R == struct) &&
		 hasMember!(pointerTarget!R, "pick")))
	{
		// commit to using the "pick" method
		static if (!isArray!R && is(typeof(r.pick(e))))
		{
			r.pick(e);
		}
		else static if (!isArray!R && is(typeof(r.pick((&e)[0..1]))))
		{
			r.pick((&e)[0..1]);
		}
		else
		{
			static assert(false,
				"Cannot pick a "~R.stringof~" into a "~E.stringof);
		}
	}
	else static if (is(typeof(e[] = r[0..e.length])))
	{
		e[] = r[0..e.length];
		r = r[e.length..$];
	}
	else static if (is(typeof({foreach (ref v; e) v = r.front, r.popFront(); }())))
	{
		foreach (ref v; e)
		{
			v = r.front;
			r.popFront();
		}
	}
	else
	{
		static assert(false,
				"Cannot pick a "~E.stringof~" into a "~R.stringof);
	}
}


/// ditto
void pick(R, E)(ref R r, ref E e)
	if (isStaticArray!E)
{
	.pick(r, e[]);
}


///
enum isEntryRange(R, E) = is(typeof(
{
	R r = void;
	E e = void;
	bool b = r.empty;
	pick!(R, E)(r, e);
}()));

static assert(isEntryRange!(ubyte[],ubyte[]));
static assert(isEntryRange!(ubyte[],ubyte));

/*******************************************************************************
 * 
 */
struct DataReader(Range, Endian rangeEndian = Endian.littleEndian)
	if (isEntryRange!(Range, ubyte[])
	||  isEntryRange!(Range, ubyte)
	||  isEntryRange!(Range, void[]))
{
private:
	Range range;
public:
	///
	this(Range r)
	{
		range = r;
	}
	
	
	/// EntryRange Primitive
	void pick(T)(ref T v)
		if (is(T == ubyte) || is(T == char) || is(T == byte))
	{
		static if (isEntryRange!(Range, typeof(v)))
		{
			.pick(range, *cast(ubyte*)&v);
		}
		else
		{
			.pick(range, (&v)[0..1]);
		}
	}
	
	
	/// ditto
	void pick(T)(T v)
		if (is(T == ubyte[])
		||  is(T == void[])
		||  is(T == char[])
		||  is(T == byte[]) )
	{
		static if (isEntryRange!(Range, ubyte[]))
		{
			.pick(range, cast(ubyte[])v);
		}
		else static if (isEntryRange!(Range, void[]))
		{
			.pick(range, cast(void[])v);
		}
		else static if ( is(Unqual!T == void[]) )
		{
			pick!(ubyte[])(cast(ubyte[])v);
		}
		else
		{
			foreach (ref e; v) .put(range, e);
		}
	}
	
	
	/// ditto
	void pick(T)(ref T v)
		if (is(T == ushort)
		||  is(T == short)
		||  is(T == wchar))
	{
		static if (rangeEndian == endian)
		{
			pick((cast(ubyte*)&v)[0..T.sizeof]);
		}
		else static if (is(Unqual!T == ushort))
		{
			pick((cast(ubyte*)&v)[0..T.sizeof]);
			v = ((v&0xff00)>>8) | ((v&0x00ff)<<8);
		}
		else
		{
			pick!(ushort)(*cast(ushort*)&v);
		}
	}
	
	
	/// ditto
	void pick(T)(ref T v)
		if (is(T == uint)
		||  is(T == int)
		||  is(T == float)
		||  is(T == ifloat) 
		||  is(T == dchar))
	{
		static if (rangeEndian == endian)
		{
			pick((cast(ubyte*)&v)[0..T.sizeof]);
		}
		else
		{
			pick((cast(ubyte*)&v)[0..T.sizeof]);
			v = bswap(*cast(uint*)&v);
		}
	}
	
	
	/// ditto
	void pick(T)(ref T v)
		if (is(T == ulong)
		||  is(T == long)
		||  is(T == double)
		||  is(T == idouble))
	{
		
		static if (rangeEndian == endian)
		{
			.pick(range, (cast(ubyte*)&v)[0..T.sizeof]);
		}
		else
		{
			ulong x;
			pick((cast(ubyte*)&v)[0..T.sizeof]);
			x = (cast(ulong)bswap(
			        cast(const uint)((v & 0xFFFFFFFF00000000) >> 32))) |
			    ((cast(ulong)bswap(
			        cast(const uint)(v & 0x00000000FFFFFFFF))) << 32);
			v = *cast(T*)&x;
		}
	}
	
	/// ditto
	void pick(T)(ref T v)
		if (is(Unqual!T U == enum) && isEntryRange!(typeof(this), OriginalType!(T)))
	{
		pick!(OriginalType!(T))(*cast(OriginalType!(T)*)&v);
	}
	
	
	/// ditto
	void pick(SrcRange)(ref SrcRange r)
		if (isStaticArray!(SrcRange))
	{
		pick!(typeof(r[]))(r[]);
	}
	
	/// ditto
	void pick(DstRange)(DstRange r)
		if (isInputRange!(DstRange)
		&& !is(ElementType!(DstRange) == ubyte)
		&& !is(DstRange == void[])
		&& !is(ElementType!(DstRange) == byte)
		&& !is(DstRange == char[])
		&& is(typeof( {foreach (ref e; r) pick(e);}() )))
	{
		static if (rangeEndian == endian && isDynamicArray!DstRange)
		{
			.pick(range, cast(ubyte[])r);
		}
		else
		{
			foreach (ref e; r)
			{
				pick(e);
			}
		}
	}
	
	/// Range primitive
	bool empty() const @property
	{
		return range.empty;
	}
}

///
DataReader!(ElementType!Range[], Endian.littleEndian) leReader(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}

/// ditto
DataReader!(Range, Endian.littleEndian) leReader(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}

///
DataReader!(ElementType!Range[], Endian.bigEndian) beReader(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}

/// ditto
DataReader!(Range, Endian.bigEndian) beReader(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}


@system unittest
{
	alias ib = DataReader!(ubyte[]);
	enum E: uint { e }
	static assert(isEntryRange!(ib, ubyte));
	static assert(isEntryRange!(ib, byte));
	static assert(isEntryRange!(ib, ushort));
	static assert(isEntryRange!(ib, short));
	static assert(isEntryRange!(ib, uint));
	static assert(isEntryRange!(ib, int));
	static assert(isEntryRange!(ib, ulong));
	static assert(isEntryRange!(ib, long));
	static assert(isEntryRange!(ib, float));
	static assert(isEntryRange!(ib, double));
	static assert(isEntryRange!(ib, char));
	static assert(isEntryRange!(ib, wchar));
	static assert(isEntryRange!(ib, dchar));
	static assert(isEntryRange!(ib, E));
	static assert(isEntryRange!(ib, ubyte[]));
	static assert(isEntryRange!(ib, byte[]));
	static assert(isEntryRange!(ib, char[]));
	static assert(isEntryRange!(ib, ushort[]));
	static assert(isEntryRange!(ib, short[]));
	static assert(isEntryRange!(ib, uint[]));
	static assert(isEntryRange!(ib, int[]));
	static assert(isEntryRange!(ib, ulong[]));
	static assert(isEntryRange!(ib, long[]));
	static assert(isEntryRange!(ib, float[]));
	static assert(isEntryRange!(ib, double[]));
	static assert(isEntryRange!(ib, char[]));
	static assert(isEntryRange!(ib, wchar[]));
	static assert(isEntryRange!(ib, dchar[]));
	static assert(isEntryRange!(ib, E[]));
	
	ubyte[16] obuf1;
	ubyte[16] obuf2;
	{
		ushort[8] ibuf = [1,2,3,4,5,6,7,8];
		ushort[8] rbuf;
		auto rlo = leWriter(obuf1);
		rlo.put(ibuf);
		auto rli = leReader(obuf1);
		rli.pick(rbuf);
		assert(rbuf == ibuf);
		
		rbuf = rbuf.init;
		
		auto rbo = beWriter(obuf2);
		rbo.put(ibuf);
		auto rbi = beReader(obuf2);
		rbi.pick(rbuf);
		assert(rbuf == ibuf);
		assert(obuf1[0..16] == [1,0,2,0,3,0,4,0,5,0,6,0,7,0,8,0]);
		assert(obuf2[0..16] == [0,1,0,2,0,3,0,4,0,5,0,6,0,7,0,8]);
	}
	{
		uint[4] ibuf = [1,2,3,4];
		uint[4] rbuf;
		auto rlo = leWriter(obuf1);
		rlo.put(ibuf);
		auto rli = leReader(obuf1);
		rli.pick(rbuf);
		assert(rbuf == ibuf);
		
		rbuf = rbuf.init;
		
		auto rbo = beWriter(obuf2);
		rbo.put(ibuf);
		auto rbi = beReader(obuf2);
		rbi.pick(rbuf);
		assert(rbuf == ibuf);
		assert(obuf1[0..16] == [1,0,0,0,2,0,0,0,3,0,0,0,4,0,0,0]);
		assert(obuf2[0..16] == [0,0,0,1,0,0,0,2,0,0,0,3,0,0,0,4]);
	}
	{
		ulong[2] ibuf = [1,2];
		ulong[2] rbuf;
		auto rlo = leWriter(obuf1);
		rlo.put(ibuf);
		auto rli = leReader(obuf1);
		rli.pick(rbuf);
		assert(rbuf == ibuf);
		
		rbuf = rbuf.init;
		
		auto rbo = beWriter(obuf2);
		rbo.put(ibuf);
		auto rbi = beReader(obuf2);
		rbi.pick(rbuf);
		assert(rbuf == ibuf);
		assert(obuf1[0..16] == [1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0]);
		assert(obuf2[0..16] == [0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,2]);
	}
}
