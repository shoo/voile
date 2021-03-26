/*******************************************************************************
 * Unique
 */
module voile.unique;

import std.traits, std.typecons, std.conv;
import core.memory;
import core.stdc.stdlib: malloc, free;
import voile.misc;

// Used by scoped() above
private extern (C) static void _d_monitordelete(Object h, bool det) pure;

/*
  Used by scoped() above.  Calls the destructors of an object
  transitively up the inheritance path, but work properly only if the
  static type of the object (T) is known.
 */
private void _destroyImpl(T)(ref T obj)
{
	object.destroy(obj);
}
private void _destroy(T)(ref T obj) pure
{
	assumePure!(_destroyImpl!T)(obj);
}

private template TypeOf(T)
{
	alias TypeOf = T;
}


private template uniqueMemberName(T, string name = "_uniqueMemberName")
{
	static if (__traits(hasMember, T, name))
	{
		enum uniqueMemberName = uniqueMemberName!(T, name~"_");
	}
	else
	{
		enum uniqueMemberName = name;
	}
}

private struct UniqueDataImpl(T)
{
	static if ((is(T==class)||is(T==interface)))
	{
		alias RefT = std.traits.Unqual!T;
	}
	else
	{
		alias InstT = std.traits.Unqual!T;
		alias RefT  = InstT*;
	}
	RefT _p;
	enum Dummy { init }
	
	/***************************************************************************
	 * 
	 */
	void attach(RefT p, size_t sz) pure
	in (_p is null)
	{
		debug (Unique) writefln("%d: Unique Attach [%08x]", __LINE__,  cast(void*)p);
		_p = p;
		assumePure!(core.memory.GC.addRange)(cast(void*)_p, sz, null);
	}
	
	
	/***************************************************************************
	 * 
	 */
	RefT detach() pure
	in (_p !is null)
	{
		debug (Unique) writefln("%d: Unique Detach [%08x]", __LINE__, cast(void*)_p);
		scope (exit)
		{
			assumePure!(core.memory.GC.removeRange)(cast(void*)_p);
			_p = null;
		}
		return _p;
	}
	
	
	
	/** Forwards member access to contents */
	static if ((is(T==class)||is(T==interface)))
	{
		@property @trusted nothrow pure
		inout(T) _instance() inout { return cast(inout(T))_p; }
//		@property @trusted nothrow pure
//		immutable(T) _instance() immutable { return cast(immutable(T))_p; }
//		@property @trusted nothrow pure
//		shared(T) _instance() shared { return cast(shared(T))_p; }
//		@property @trusted nothrow pure
//		const(shared(T)) _instance() const shared { return cast(const(shared(T)))_p; }
	}
	else
	{
		@property @trusted nothrow pure
		ref inout(T) _instance() inout { return *cast(inout(T)*)_p; }
//		@property @trusted nothrow pure
//		ref immutable(T) _instance() immutable { return *cast(immutable(T)*)_p; }
//		@property @trusted nothrow pure
//		ref shared(T) _instance() shared { return *cast(shared(T)*)_p; }
//		@property @trusted nothrow pure
//		ref const(shared(T)) _instance() const shared { return *cast(const(shared(T))*)_p; }
	}
	
	
	/***************************************************************************
	 * 
	 */
	@trusted pure
	void release()
	{
		if (!_p)
			return;
		debug (Unique) writefln("%d: Unique [%08x] release of [%08x]", __LINE__, cast(void*)&this, cast(void*)_p);
		scope (exit)
			detach();
		static if (is(T==interface))
		{
			if (auto o = cast(Object)_p)
			{
				_destroy(o);
				if ((cast(void**)(cast(void*)o))[1]) // if monitor is not null
				{
					_d_monitordelete(o, true);
				}
			}
		}
		else static if (is(T ==struct))
		{
			_destroy(*_p);
		}
		else
		{
			auto p = _p;
			_destroy(p);
		}
		assumePure!free(cast(void*)_p);
	}
	
	///
	static if (__traits(compiles, hashOf(_instance())))
	{
		hash_t toHash() const nothrow @trusted
		{
			try
				return hashOf(_instance());
			catch (Throwable e)
				return hash_t.init;
		}
	}
	
	/***************************************************************************
	 * Nullifies the current contents.
	 */
	@property @safe pure nothrow
	bool isEmpty(this This)()
	{
		return _p is null;
	}
	
	alias _instance this;
}


/*******************************************************************************
 * 
 */
struct Unique(T)
{
private:
	mixin("UniqueDataImpl!(T) "~uniqueMemberName!T~";");
	/***************************************************************************
	 * Constructor
	 */
	this(U)(U p, TypeOf!(__traits(getMember, Unique, uniqueMemberName!T).Dummy) dummy) pure
		if (is(U == TypeOf!((__traits(getMember, Unique, uniqueMemberName!T).RefT))))
	{
		debug (Unique) writefln("%d: Unique constructor [%08x]", __LINE__, cast(void*)&this, cast(void*)_p);
		__traits(getMember, this, uniqueMemberName!T)._p = p;
	}
	
	/***************************************************************************
	 * Constructor that takes an rvalue.
	 * It will ensure uniqueness, as long as the rvalue
	 * isn't just a view on an lvalue (e.g., a cast)
	 * Typical usage:
	 *----
	 *Unique!(Foo) f = new Foo;
	 *----
	 */
	this(U)(U p, size_t sz) if (is(U == TypeOf!(__traits(getMember, Unique, uniqueMemberName!T).RefT)))
	{
		debug (Unique) writefln("%d: Unique [%08x] constructor with rvalue [%08x]", __LINE__, cast(void*)&this, cast(void*)p);
		__traits(getMember, this, uniqueMemberName!T).attach(p, sz);
		assert(__traits(getMember, this, uniqueMemberName!T)._p);
	}
	
public:
	
	
	
	/***************************************************************************
	 * Postblit operator is undefined to prevent the cloning of $(D Unique)
	 * objects
	 */
	@disable this(this);
	
	
	/***************************************************************************
	 * Constructor that takes an rvalue.
	 * It will ensure uniqueness, as long as the rvalue
	 * isn't just a view on an lvalue (e.g., a cast)
	 * Typical usage:
	 *----
	 *Unique!(Foo) f = unique!Bar;
	 *----
	 */
	this(U)(Unique!U u)
		if (!is(U == T) && is(U: T))
	{
		debug (Unique) writefln("%d: Unique [%08x] other type constructor with rvalue [%08x]",
		                        __LINE__, cast(void*)&this,
		                        cast(void*)__traits(getMember, u, uniqueMemberName!U)._p);
		__traits(getMember, this, uniqueMemberName!T)._p = __traits(getMember, u, uniqueMemberName!U)._p;
		__traits(getMember, u, uniqueMemberName!U)._p = null;
	}
	
	
	~this() pure
	{
		debug (Unique) writefln("%d: Unique [%08x] destructor [%08x]",
		                        __LINE__, cast(void*)&this,
		                        cast(void*)__traits(getMember, this, uniqueMemberName!T)._p);
		__traits(getMember, this, uniqueMemberName!T).release();
	}
	
	/***************************************************************************
	 * 
	 */
	@safe
	void proxySwap()(ref Unique u)
		if (!is(typeof(T.init.proxySwap(T.init))))
	{
		debug (Unique) writefln("%d: Unique [%08x] swap [%08x]",
		                        __LINE__, cast(void*)&this,
		                        cast(void*)__traits(getMember, u, uniqueMemberName!T)._p);
		auto tmp = __traits(getMember, this, uniqueMemberName!T)._p;
		__traits(getMember, this, uniqueMemberName!T)._p = __traits(getMember, u, uniqueMemberName!T)._p;
		__traits(getMember, u, uniqueMemberName!T)._p = tmp;
	}
	
	///
	ref Unique opAssign(Unique u)
	in (__traits(getMember, this, uniqueMemberName!T)._p is null)
	{
		debug (Unique) writefln("%d: Unique [%08x] assign [%08x]",
		                        __LINE__, cast(void*)&this,
		                        cast(void*)__traits(getMember, u, uniqueMemberName!T)._p);
		__traits(getMember, this, uniqueMemberName!T)._p = __traits(getMember, u, uniqueMemberName!T)._p;
		__traits(getMember, u, uniqueMemberName!T)._p = null;
		return this;
	}
	
	mixin Proxy!(mixin(uniqueMemberName!T));
}


/*******************************************************************************
 * 
 */
Unique!T unique(T, Args...)(Args args) @trusted
	if (((is(T == class) || is(T == struct) || is(T == union)) && !isNested!T)
	 || !(is(T == class) || is(T == struct) || is(T == union)))
{
	return uniqueImpl!(T)(args);
}

private Unique!T uniqueImpl(T, Args...)(Args args)
	if (is(Unique!T))
{
	mixin("alias Unique!T."~uniqueMemberName!T~".RefT RefT;");
	static if (is(T == class))
	{
		enum instSize = __traits(classInstanceSize, T);
		return Unique!T(emplace!T(malloc(instSize)[0..instSize], args), instSize);
	}
	else
	{
		enum instSize = T.sizeof;
		return Unique!T(emplace(cast(RefT)malloc(instSize), args), instSize);
	}
}

///
void release(T)(ref Unique!T u)
{
	return __traits(getMember, u, uniqueMemberName!T).release();
}

///
bool isEmpty(T)(ref Unique!T u)
{
	return __traits(getMember, u, uniqueMemberName!T).isEmpty;
}


@system unittest
{
	import std.algorithm: move;
	static int[] testary;
	{
		static struct Foo
		{
			~this() { testary ~= -1; }
			@property int val() const { return 3; }
		}
		alias UFoo = Unique!(Foo);
	
		UFoo f(UFoo u)
		{
			debug (Unique) writefln("%d: Unique [%08x] enter foo", __LINE__, cast(void*)&u);
			testary ~= -2;
			return move(u);
		}
		testary ~= 1;
		auto uf = unique!Foo;
		debug (Unique) writefln("%d: Unique [%08x] make", __LINE__, cast(void*)&uf);
		testary ~= 2;
		assert(!isEmpty(uf));
		assert(uf.val() == 3);
		// should not compile
		static assert(!__traits(compiles,
		{
			auto uf3 = f(uf);
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			uf = uf;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			auto uf2 = uf;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			Foo x = uf;
		}));
		auto uf2 = f(move(uf));
		debug (Unique) writefln("%d: Unique [%08x] returned foo", __LINE__, cast(void*)&uf);
		debug (Unique) writefln("%d: Unique [%08x] returned foo", __LINE__, cast(void*)&uf2);
		testary ~= 3;
		assert(isEmpty(uf));
		assert(!isEmpty(uf2));
	}
	testary ~= 4;
	assert(testary == [1,2,-2,3,-1,4]);
}

@system unittest
{
	import std.algorithm: move;
	static int[] testary;
	{
		static class Bar
		{
			~this() { testary ~= -1; }
			@property int val() const { return 4; }
		}
		alias UBar = Unique!(Bar);
		UBar g(UBar u)
		{
			testary ~= -2;
			return move(u);
		}
		testary ~= 1;
		auto ub = unique!Bar;
		testary ~= 2;
		assert(!isEmpty(ub));
		assert(ub.val == 4);
		// should not compile
		static assert(!__traits(compiles,
		{
			auto ub3 = g(ub);
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			ub = ub;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			auto ub2 = ub;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			Bar x = ub;
		}));
		auto ub2 = g(move(ub));
		testary ~= 3;
		assert(isEmpty(ub));
		assert(!isEmpty(ub2));
	}
	testary ~= 4;
	assert(testary == [1,2,-2,3,-1,4]);
}

@system unittest
{
	import std.algorithm: move;
	static int[] testary;
	{
		static class A
		{
			~this() { testary ~= -1; }
			@property int val() const { return 4; }
		}
		static class B: A
		{
			~this() { testary ~= -2; }
			@property override int val() const { return 5; }
		}
		testary ~= 1;
		auto b = unique!B;
		// should compile
		static assert(__traits(compiles,
		{
			Unique!A a3 = move(b);
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			Unique!A a3 = b;
		}));
		// should compile
		static assert(__traits(compiles,
		{
			Unique!A a3 = unique!B;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			B bb = b;
		}));
		// should not compile
		static assert(!__traits(compiles,
		{
			A bb = b;
		}));
		testary ~= 2;
		Unique!A a = move(b);
		testary ~= 3;
		assert(isEmpty(b));
		assert(!isEmpty(a));
		assert(a.val == 5);
		Unique!A a2;
		testary ~= 4;
		a2 = unique!A;
		testary ~= 5;
	}
	testary ~= 6;
	assert(testary == [1,2,3,4,5,-1,-2,-1,6]);
}


@system unittest
{
	import std.algorithm: move;
	static int[] testary;
	{
		static class A
		{
			this() { testary ~= -1; }
			~this() { testary ~= -2; }
			@property int val() const { return 4; }
		}
		static class Foo
		{
			Unique!A a;
			this()
			{
				testary ~= -3;
				a = unique!A;
			}
			~this()
			{
				testary ~= -4;
				release(a);
			}
		}
		testary ~= 1;
		auto f = unique!Foo;
		testary ~= 2;
		assert(f.a.val == 4);
	}
	testary ~= 3;
	assert(testary == [1,-3,-1,2,-4,-2,3]);
}

@system unittest
{
	import std.typetuple, std.algorithm;
	struct S1 { int x; }
	struct S2 { Unique!int x; }
	static class C1 { int x; }
	static class C2 { Unique!int x; }
	foreach (T; TypeTuple!(
		int, real, const(int), shared(int), shared(const(int)),
		int*, real*, const(int)*, shared(int)*, shared(const(int))*,
		S1, S2, C1, C2
		))
	{
		auto u1 = unique!T();
		auto u2 = u1.move();
		static assert(is(typeof(u2) == Unique!T));
		static assert(!__traits(compiles, { auto u3 = u2; }));
	}
	
	{
		auto u = unique!S1();
		auto cu = unique!(const(S1))();
		auto iu = unique!(immutable(S1))();
		auto su = unique!(shared(S1))();
		auto csu = unique!(const shared S1)();
		auto x  = u.x;
		auto cx = cu.x;
		auto ix = iu.x;
		auto sx = su.x;
		auto csx = csu.x;
		static assert(is(typeof(x)  == int));
		static assert(is(typeof(cx) == const(int)));
		static assert(is(typeof(ix) == immutable(int)));
		static assert(is(typeof(sx) == shared(int)));
		static assert(is(typeof(csx) == const(shared int)));
	}
	{
		auto u   = unique!S1();
		auto cu  = cast(const) &u;
		auto iu  = cast(immutable) &u;
		auto su  = cast(shared) &u;
		auto csu = cast(const shared) &u;
		auto x   = u.x;
		auto cx  = cu.x;
		auto ix  = iu.x;
		// multiple alias this is needed...
		//auto sx  = su.x;
		//auto csx = csu.x;
		static assert(is(typeof(x)  == int));
		static assert(is(typeof(cx) == const(int)));
		static assert(is(typeof(ix) == immutable(int)));
		// multiple alias this is needed...
		//static assert(is(typeof(sux) == shared(int)));
		//static assert(is(typeof(csx) == const(shared int)));
	}
}


/*******************************************************************************
 * 生データを利用できない形で返す
 */
auto toRawData(T)(ref Unique!T u)
{
	static struct Data {}
	scope (exit)
		__traits(getMember, u, uniqueMemberName!T)._p = null;
	return cast(Data*)__traits(getMember, u, uniqueMemberName!T)._p;
}

/*******************************************************************************
 * 生データから利用できる形のUnique型へと変換する
 */
auto toUnique(T)(ref ReturnType!(toRawData!T) d)
{
	mixin("alias Unique!T."~uniqueMemberName!T~".RefT RefT;");
	mixin("alias Unique!T."~uniqueMemberName!T~".Dummy Dummy;");
	enum instSize = T.sizeof;
	scope (exit)
		d = null;
	return Unique!T(cast(RefT)d, Dummy.init);
}
