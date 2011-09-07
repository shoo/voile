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
	if (isOutputRange!(Range, const(ubyte)[]) || isOutputRange!(Range, ubyte))
{
private:
	Range range;
public:
	
	
	
	void put(T)(in T v)
		if (is(Unqual!T == ubyte))
	{
		static if (isOutputRange!(Range, ubyte))
		{
			.put(range, v);
		}
		else
		{
			.put(range, (&v)[0..1]);
		}
	}
	
	
	void put(T)(in T v)
		if (is(Unqual!T == ubyte[]))
	{
		static if (isOutputRange!(Range, typeof(v)))
		{
			.put(range, v);
		}
		else
		{
			foreach (ref e; v) .put(range, e);
		}
	}
	
	
	void put(T)(T v)
		if (is(Unqual!T == byte))
	{
		put!(const ubyte)(cast(const ubyte)v);
	}
	
	
	void put(T)(in T v)
		if (is(Unqual!T == ushort) || is(Unqual!T == short))
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
	
	
	void put(T)(in T v)
		if (is(Unqual!T == uint) || is(Unqual!T == int)
		||  is(Unqual!T == float) || is(Unqual!T == ifloat) )
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
	
	
	void put(T)(in T v)
		if (is(Unqual!T == ulong) || is(Unqual!T == long) ||
		    is(Unqual!T == double) || is(Unqual!T == idouble) )
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
			        cast(const uint)((v & 0x00000000FFFFFFFF)))) << 32);
			put!(const(ubyte)[])((cast(const(ubyte)*)&x)[0..8]);
		}
	}
	
	
	void put(SrcRange)(ref const(SrcRange) r)
		if (isStaticArray!(SrcRange))
	{
		put!(typeof(r[]))(r[]);
	}
	
	
	void put(SrcRange)(const(SrcRange) r)
		if (isInputRange!(SrcRange)
		&& !is(ElementType!(SrcRange) == ubyte)
		&& is(typeof( {foreach (e; r) put(e);}() )))
	{
		foreach (e; r) put(e);
	}
}

DataWriter!(ElementType!Range[], Endian.littleEndian) leWriter(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}

DataWriter!(Range, Endian.littleEndian) leWriter(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}

DataWriter!(ElementType!Range[], Endian.bigEndian) beWriter(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}

DataWriter!(Range, Endian.bigEndian) beWriter(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}

unittest
{
	alias DataWriter!(ubyte[]) ob;
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
	static assert(isOutputRange!(ob, shared ubyte));
	static assert(isOutputRange!(ob, shared byte));
	static assert(isOutputRange!(ob, shared ushort));
	static assert(isOutputRange!(ob, shared short));
	static assert(isOutputRange!(ob, shared uint));
	static assert(isOutputRange!(ob, shared int));
	static assert(isOutputRange!(ob, shared ulong));
	static assert(isOutputRange!(ob, shared long));
	static assert(isOutputRange!(ob, shared float));
	static assert(isOutputRange!(ob, shared double));
	static assert(isOutputRange!(ob, shared ubyte[]));
	static assert(isOutputRange!(ob, shared byte[]));
	static assert(isOutputRange!(ob, shared ushort[]));
	static assert(isOutputRange!(ob, shared short[]));
	static assert(isOutputRange!(ob, shared uint[]));
	static assert(isOutputRange!(ob, shared int[]));
	static assert(isOutputRange!(ob, shared ulong[]));
	static assert(isOutputRange!(ob, shared long[]));
	static assert(isOutputRange!(ob, shared float[]));
	static assert(isOutputRange!(ob, shared double[]));
	static assert(isOutputRange!(ob, shared(const(ubyte))));
	static assert(isOutputRange!(ob, shared(const(byte))));
	static assert(isOutputRange!(ob, shared(const(ushort))));
	static assert(isOutputRange!(ob, shared(const(short))));
	static assert(isOutputRange!(ob, shared(const(uint))));
	static assert(isOutputRange!(ob, shared(const(int))));
	static assert(isOutputRange!(ob, shared(const(ulong))));
	static assert(isOutputRange!(ob, shared(const(long))));
	static assert(isOutputRange!(ob, shared(const(float))));
	static assert(isOutputRange!(ob, shared(const(double))));
	static assert(isOutputRange!(ob, shared(const(ubyte[]))));
	static assert(isOutputRange!(ob, shared(const(byte[]))));
	static assert(isOutputRange!(ob, shared(const(ushort[]))));
	static assert(isOutputRange!(ob, shared(const(short[]))));
	static assert(isOutputRange!(ob, shared(const(uint[]))));
	static assert(isOutputRange!(ob, shared(const(int[]))));
	static assert(isOutputRange!(ob, shared(const(ulong[]))));
	static assert(isOutputRange!(ob, shared(const(long[]))));
	static assert(isOutputRange!(ob, shared(const(float[]))));
	static assert(isOutputRange!(ob, shared(const(double[]))));
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




void get(R, E)(R r, ref E e)
	if (!isArray!E)
{
	static if (hasMember!(R, "get") ||
		(isPointer!R && is(pointerTarget!R == struct) &&
		 hasMember!(pointerTarget!R, "get")))
	{
		// commit to using the "get" method
		static if (!isArray!R && is(typeof(r.get(e))))
		{
			r.get(e);
		}
		else static if (!isArray!R && is(typeof(r.get((&e)[0..1]))))
		{
			r.get((&e)[0..1]);
		}
		else
		{
			static assert(false,
				"Cannot get a "~R.stringof~" into a "~E.stringof);
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
			else static if (isInputRange!E && is(typeof(get(r, e.front))))
			{
				for (; !e.empty; e.popFront()) get(r, e.front);
			}
			else
			{
				static assert(false,
						"Cannot put a "~E.stringof~" into a "~R.stringof);
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
						"Cannot put a "~E.stringof~" into a "~R.stringof);
			}
		}
	}
}


void get(R, E)(ref R r, E e)
	if (isDynamicArray!E)
{
	static if (hasMember!(R, "get") ||
		(isPointer!R && is(pointerTarget!R == struct) &&
		 hasMember!(pointerTarget!R, "get")))
	{
		// commit to using the "get" method
		static if (!isArray!R && is(typeof(r.get(e))))
		{
			r.get(e);
		}
		else static if (!isArray!R && is(typeof(r.get((&e)[0..1]))))
		{
			r.get((&e)[0..1]);
		}
		else
		{
			static assert(false,
				"Cannot get a "~R.stringof~" into a "~E.stringof);
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
				"Cannot put a "~E.stringof~" into a "~R.stringof);
	}
}


void get(R, E)(ref R r, ref E e)
	if (isStaticArray!E)
{
	.get(r, e[]);
}


template isEntryRange(R, E)
{
	enum isEntryRange = is(typeof({ R r; E e; get!(R, E)(r, e); }()));
}

static assert(isEntryRange!(ubyte[],ubyte[]));
static assert(isEntryRange!(ubyte[],ubyte));

struct DataReader(Range, Endian rangeEndian = Endian.littleEndian)
	if (isEntryRange!(Range, ubyte[]) || isEntryRange!(Range, ubyte))
{
private:
	Range range;
public:
	this(Range r)
	{
		range = r;
	}
	
	
	
	
	void get(T)(ref T v)
		if (is(Unqual!T == ubyte))
	{
		static if (isEntryRange!(Range, typeof(v)))
		{
			.get(range, v);
		}
		else
		{
			.get(range, (&v)[0..1]);
		}
	}
	
	
	void get(T)(T v)
		if (is(Unqual!T == ubyte[]))
	{
		static if (isEntryRange!(Range, typeof(v)))
		{
			.get(range, v);
		}
		else
		{
			foreach (ref e; v) .get(range, e);
		}
	}
	
	
	void get(T)(ref T v)
		if (is(Unqual!T == byte))
	{
		static if (isEntryRange!(Range, typeof(v)))
		{
			.get(range, v);
		}
		else
		{
			foreach (ref e; v) .get(range, e);
		}
	}
	
	
	void get(T)(ref T v)
		if (is(Unqual!T == ushort) || is(Unqual!T == short))
	{
		static if (rangeEndian == endian)
		{
			get((cast(ubyte*)&v)[0..T.sizeof]);
		}
		else static if (is(Unqual!T == ushort))
		{
			get((cast(ubyte*)&v)[0..T.sizeof]);
			v = ((v&0xff00)>>8) | ((v&0x00ff)<<8);
		}
		else
		{
			get!(ushort)(*cast(ushort*)&v);
		}
	}
	
	
	void get(T)(ref T v)
		if (is(Unqual!T == uint) || is(Unqual!T == int)
		||  is(Unqual!T == float) || is(Unqual!T == ifloat) )
	{
		static if (rangeEndian == endian)
		{
			get((cast(ubyte*)&v)[0..T.sizeof]);
		}
		else
		{
			get((cast(ubyte*)&v)[0..T.sizeof]);
			v = bswap(*cast(uint*)&v);
		}
	}
	
	
	void get(T)(ref T v)
		if (is(Unqual!T == ulong) || is(Unqual!T == long) ||
		    is(Unqual!T == double) || is(Unqual!T == idouble) )
	{
		
		static if (rangeEndian == endian)
		{
			.get(range, (cast(ubyte*)&v)[0..T.sizeof]);
		}
		else
		{
			ulong x;
			get((cast(ubyte*)&v)[0..T.sizeof]);
			x = (cast(ulong)bswap(
			        cast(const uint)((v & 0xFFFFFFFF00000000) >> 32))) |
			    ((cast(ulong)bswap(
			        cast(const uint)((v & 0x00000000FFFFFFFF)))) << 32);
			v = *cast(T*)&x;
		}
	}
	
	
	void get(SrcRange)(ref SrcRange r)
		if (isStaticArray!(SrcRange))
	{
		get!(typeof(r[]))(r[]);
	}
	
	void get(DstRange)(DstRange r)
		if (isInputRange!(DstRange)
		&& !is(ElementType!(DstRange) == ubyte)
		&& is(typeof( {foreach (ref e; r) get(e);}() )))
	{
		static if (rangeEndian == endian && isDynamicArray!DstRange)
		{
			.get(range, cast(ubyte[])r);
		}
		else
		{
			foreach (ref e; r)
			{
				get(e);
			}
		}
	}
}

DataReader!(ElementType!Range[], Endian.littleEndian) leReader(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}

DataReader!(Range, Endian.littleEndian) leReader(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}

DataReader!(ElementType!Range[], Endian.bigEndian) beReader(Range)(ref Range r)
	if (isStaticArray!(Range))
{
	return typeof(return)(r[]);
}

DataReader!(Range, Endian.bigEndian) beReader(Range)(Range r)
	if (isOutputRange!(Range, ubyte[])
	||  isOutputRange!(Range, ubyte))
{
	return typeof(return)(r);
}


unittest
{
	alias DataReader!(ubyte[]) ib;
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
	static assert(isEntryRange!(ib, ubyte[]));
	static assert(isEntryRange!(ib, byte[]));
	static assert(isEntryRange!(ib, ushort[]));
	static assert(isEntryRange!(ib, short[]));
	static assert(isEntryRange!(ib, uint[]));
	static assert(isEntryRange!(ib, int[]));
	static assert(isEntryRange!(ib, ulong[]));
	static assert(isEntryRange!(ib, long[]));
	static assert(isEntryRange!(ib, float[]));
	static assert(isEntryRange!(ib, double[]));
	ubyte[16] obuf1;
	ubyte[16] obuf2;
	{
		ushort[8] ibuf = [1,2,3,4,5,6,7,8];
		ushort[8] rbuf;
		auto rlo = leWriter(obuf1);
		rlo.put(ibuf);
		auto rli = leReader(obuf1);
		rli.get(rbuf);
		assert(rbuf == ibuf);
		
		rbuf = rbuf.init;
		
		auto rbo = beWriter(obuf2);
		rbo.put(ibuf);
		auto rbi = beReader(obuf2);
		rbi.get(rbuf);
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
		rli.get(rbuf);
		assert(rbuf == ibuf);
		
		rbuf = rbuf.init;
		
		auto rbo = beWriter(obuf2);
		rbo.put(ibuf);
		auto rbi = beReader(obuf2);
		rbi.get(rbuf);
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
		rli.get(rbuf);
		assert(rbuf == ibuf);
		
		rbuf = rbuf.init;
		
		auto rbo = beWriter(obuf2);
		rbo.put(ibuf);
		auto rbi = beReader(obuf2);
		rbi.get(rbuf);
		assert(rbuf == ibuf);
		assert(obuf1[0..16] == [1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0]);
		assert(obuf2[0..16] == [0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,2]);
	}
}
