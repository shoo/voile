
/*******************************************************************************
 * 参照カウンタ
 */
module voile.refcnt;


import std.traits;
import std.functional: toDelegate;
import voile.handler: DelegateTypeOf;


/*******************************************************************************
 * アロケータ
 * 
 * CountedDataを作成する際、メモリを割り当てる関数の型。
 */
alias Allocator = CountedInstance* delegate() pure nothrow;

/*******************************************************************************
 * デアロケータ
 * 
 * CountedDataを解放する際、メモリを解放する関数の型。
 */
alias Deallocator = void delegate(CountedInstance* instance) pure nothrow @nogc;

/*******************************************************************************
 * アロケータかどうかを判定する
 */
template isAllocator(T...)
if (T.length > 0 && isCallable!(T[0]))
{
	enum bool isAllocator = isAssignable!(Allocator, DelegateTypeOf!(T[0]));
}
///
@system unittest
{
	static assert(isAllocator!(CountedInstance* delegate() @safe pure nothrow));
	static assert(isAllocator!(CountedInstance* delegate() @system pure nothrow const));
	static assert(isAllocator!(CountedInstance* delegate() @system pure nothrow @nogc));
	static assert(!isAllocator!(CountedInstance* delegate() @system nothrow @nogc));
	static assert(!isAllocator!(CountedInstance* delegate() @system pure @nogc));
	
	void aaa();
	static assert(!isAllocator!aaa);
	CountedInstance* bbb() pure nothrow;
	static assert(isAllocator!bbb);
	
}

/*******************************************************************************
 * デアロケータかどうかを判定する
 */
template isDeallocator(T...)
if (T.length > 0 && isCallable!(T[0]))
{
	static if (isFunction!(T[0]))
	{
		enum bool isDeallocator = isAssignable!(Deallocator, typeof(toDelegate(typeof(&T[0]).init)));
	}
	else
	{
		enum bool isDeallocator = isAssignable!(Deallocator, typeof(toDelegate(T.init)));
	}
}
///
@system unittest
{
	static assert(isDeallocator!(void delegate(CountedInstance*) @safe pure nothrow @nogc));
	static assert(isDeallocator!(void delegate(CountedInstance*) @system pure nothrow @nogc));
	static assert(isDeallocator!(void delegate(CountedInstance*) @system pure nothrow @nogc inout));
	static assert(!isDeallocator!(void delegate(CountedInstance*) @system nothrow @nogc const));
	static assert(!isDeallocator!(void delegate(CountedInstance*) @system pure @nogc));
	
	void aaa();
	static assert(!isDeallocator!aaa);
	void bbb(CountedInstance*) pure nothrow @nogc;
	static assert(isDeallocator!bbb);
}

/*******************************************************************************
 * malloc/freeによるアロケータ
 */
auto defaultAllocatorByMalloc(size_t bufSize = 0) pure nothrow @nogc @safe
{
	import core.exception: OutOfMemoryError;
	import core.stdc.stdlib;
	import core.memory;
	import std.traits;
	import voile.misc: assumePure, nogcEnforce, assumeNogc;
	static struct Alloc
	{
		size_t bufSize;
		this(size_t s) pure nothrow @nogc @safe
		{
			bufSize = s;
		}
		private CountedInstance* callImpl() nothrow
		{
			auto newSize = CountedInstance.sizeof + bufSize;
			auto buf = (cast(ubyte*)malloc(newSize).nogcEnforce!OutOfMemoryError())[0..newSize];
			GC.addRange(buf.ptr, buf.length, null);
			GC.setAttr(buf.ptr, GC.BlkAttr.NO_MOVE);
			auto ret = cast(CountedInstance*)buf.ptr;
			ret.counter = 1;
			ret.rawData = buf[CountedInstance.sizeof..$];
			ret.deallocator = toDelegate((CountedInstance* inst)
			{
				assumePure!(GC.removeRange)(inst);
				assumePure!free(inst);
			});
			return ret;
		}
		CountedInstance* opCall() pure nothrow
		{
			return assumeNogc(assumePure(&callImpl))();
		}
	}
	return Alloc(bufSize);
}

/*******************************************************************************
 * GCによるアロケータ
 */
auto defaultAllocatorByGC(size_t bufSize = 0) pure nothrow
{
	static struct Alloc
	{
		size_t bufSize;
		this(size_t s) pure nothrow @nogc @safe
		{
			bufSize = s;
		}
		CountedInstance* opCall() pure nothrow
		{
			auto newSize = CountedInstance.sizeof + bufSize;
			auto buf = new ubyte[newSize];
			auto ret = cast(CountedInstance*)buf.ptr;
			ret.counter = 1;
			ret.rawData = buf[CountedInstance.sizeof..$];
			return ret;
		}
	}
	return Alloc(bufSize);
}

/*******************************************************************************
 * 参照カウンタ用のデータを作成する
 */
struct CountedInstance
{
	/// 参照カウンタ
	int     counter;
	/// 生データ(データのインスタンスと拡張領域を含むメモリ領域全体)
	ubyte[] rawData;
	/// 解放時に呼び出すためのコールバック
	Deallocator deallocator;
}

/*******************************************************************************
 * 参照カウンタ用のデータを作成するmixinテンプレート
 */
mixin template CountedImpl(T)
{
	private CountedInstance* _instance;
	
	/***************************************************************************
	 * 生データ(データのインスタンスと拡張領域を含むメモリ領域全体)
	 */
	inout(ubyte)[] buffer() @safe @nogc pure nothrow inout @property
	in (_instance)
	{
		return _instance.rawData;
	}
	
	/***************************************************************************
	 * データのインスタンス
	 */
	ref inout(T) data() @trusted @nogc pure nothrow inout @property
	in (_instance)
	in (_instance.rawData.length >= T.sizeof)
	{
		return *cast(inout T*)&_instance.rawData[0];
	}
	
	/***************************************************************************
	 * 拡張データ領域
	 */
	inout(ubyte)[] extra() @safe @nogc pure nothrow inout @property
	in (_instance)
	in (_instance.rawData.length >= T.sizeof)
	{
		return _instance.rawData[T.sizeof..$];
	}
	
	/***************************************************************************
	 * 初期化する
	 * 
	 * Note:
	 *      本関数を呼び出して初期化した場合、正しくrelease(CountedInstanceのdeallocatorの呼び出し)をしなければ
	 *      メモリリークする
	 */
	void initializeCountedInstance(ubyte[] refbuf) @system pure @nogc
	{
		initializeCountedInstance(defaultAllocatorByMalloc(0));
		_instance.rawData = refbuf;
	}
	/// ditto
	void initializeCountedInstance(size_t bufSize = T.sizeof) @system pure @nogc
	{
		initializeCountedInstance(defaultAllocatorByMalloc(bufSize));
	}
	/// ditto
	void initializeCountedInstance(Alloc)(scope Alloc alloc)
	{
		import voile.misc: assumeNogc, nogcEnforce;
		if (_instance && _instance.counter > 0)
		{
			assert(_instance);
			// 解放の際にはGCは走らないはず…
			assumeNogc(_instance.deallocator)(_instance);
			_instance = null;
		}
		_instance = alloc().nogcEnforce();
	}
	
	/***************************************************************************
	 * キャスト
	 */
	bool opCast(T)() @safe nothrow pure @nogc const
	if (is(T == bool))
	{
		return _instance !is null;
	}
	
	/***************************************************************************
	 * 参照カウンタ加算
	 */
	int addRef() @system pure @nogc
	in (_instance)
	{
		return ++_instance.counter;
	}
	
	/***************************************************************************
	 * 参照カウンタ減算と解放
	 */
	int release() @system pure
	in (_instance)
	{
		import core.stdc.stdlib;
		auto ret = --_instance.counter;
		if (ret == 0)
		{
			if (_instance.rawData.ptr)
			{
				if (_instance.deallocator)
					_instance.deallocator(_instance);
			}
			_instance = null;
		}
		return ret;
	}
}


/*******************************************************************************
 * 参照カウントを持つを形成する(RefCounted専用)
 * 
 * CountedImplを実装しており、isCountedData!Tでtrueを返す型です。
 * ただし、メソッドはすべてモジュール内ローカルとなっており、アクセスは許されません。
 * かならずRefCountedを通してアクセスしてください。
 */
struct CountedData(T)
{
private:
	mixin CountedImpl!T _impl;
}

private enum bool isRef(T) = is(T == class) || is(T == interface) || isPointer!T || isAssociativeArray!T;

/*******************************************************************************
 * RefCountedにできるデータか検証する
 * 
 * RefCountedに直接対応可能な型は以下の特徴を備えています。
 *  - 参照型か、ポインタのサイズと同じサイズ
 *  - releaseまたはRelease関数を備えていて、それらは整数を返す
 *  - addRefまたはAddRef関数を備えていて、それらは整数を返す
 * 
 * 上記に該当しない場合、RefCounted!Tとすると、自動的に上記特徴を備えたCountedData!Tが内部的に使用されます。
 * 
 * Params:
 *      T = 調べたい型
 * See_Also:
 *      $(LINK2 #.CountedData, CountedData)
 */
template isCountedData(T)
{
	static if ((isRef!T || T.sizeof == size_t.sizeof)
	 && ((is(typeof(T.Release()) U1) && isIntegral!U1)
	  || (is(typeof(T.release()) U2) && isIntegral!U2))
	 && ((is(typeof(T.AddRef()) U3) && isIntegral!U3)
	  || (is(typeof(T.addRef()) U4) && isIntegral!U4)))
	{
		enum isCountedData = true;
	}
	else
	{
		enum isCountedData = false;
	}
}

///
@system unittest
{
	static struct S1 {}
	static assert(!isCountedData!S1);
	static assert(isCountedData!(CountedData!S1));
	static struct S2 { size_t x; uint release() {return 0;} uint addRef(){return 0;} }
	static assert(isCountedData!S2);
	static assert(isCountedData!(CountedData!S2));
	
	class C1 {}
	static assert(!isCountedData!C1);
	class C2 { uint release(){return 0;} uint addRef(){return 0;}}
	static assert( isCountedData!C2);
	
	static assert(!isCountedData!int);
	static assert(!isCountedData!(int*));
	static assert(isCountedData!(CountedData!int));
	
}

// ユニークなメンバ名を取得する
private template uniqueMemberName(T, string name = "_uniqueMemberName", uint num = 0)
{
	import std.conv;
	enum string candidate = num == 0 ? name : text(name, num);
	static if (__traits(hasMember, T, candidate))
	{
		enum string uniqueMemberName = uniqueMemberName!(T, name, num+1);
	}
	else
	{
		enum string uniqueMemberName = candidate;
	}
}

// 参照の型
private template RefType(T)
{
	static if (isCountedData!T)
	{
		alias RefType = T;
	}
	else
	{
		alias RefType = CountedData!T;
	}
}

/*******************************************************************************
 * 参照カウンタのあるデータを管理する
 * 
 * isCountedDataなデータの参照カウントをコピーの発生や寿命の終了で自動的に増減させる。
 * 
 * Params:
 *      T = isCountedDataなclass/interface/structのポインタ/size_tと同サイズのstruct、およびCountedDataのインスタンス
 * See_Also:
 *      $(LINK2 #.isCountedData, isCountedData)
 */
struct RefCounted(T)
{
private:
	mixin(`RefType!T ` ~ uniqueMemberName!(T, "_data") ~ `;`);
public:
	static if (isCountedData!T)
	{
		mixin(`ref inout(T) ` ~ uniqueMemberName!(T, "_refData") ~ `() pure nothrow @nogc @safe inout @property
		{
			return ` ~ uniqueMemberName!(T, "_data") ~ `;
		}`);
	}
	else
	{
		mixin(`ref inout(T) ` ~ uniqueMemberName!(T, "_refData") ~ `() pure nothrow @nogc @safe inout @property
		{
			return ` ~ uniqueMemberName!(T, "_data") ~ `._impl.data;
		}`);
	}
	
	/***************************************************************************
	 * 参照カウンタを保持してアタッチ＆加算する
	 */
	this(U)(U newRefData) @trusted
	if (is(U : RefType!T))
	{
		__traits(getMember, this, uniqueMemberName!(T, "_data")) = newRefData;
		
		if (isInitialized(this))
		{
			static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).addRef)))
				__traits(getMember, this, uniqueMemberName!(T, "_data")).addRef();
			else static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).AddRef)))
				__traits(getMember, this, uniqueMemberName!(T, "_data")).AddRef();
			else static assert(0);
		}
	}
	
	/***************************************************************************
	 * 参照のコピーを作成し、参照カウンタを加算する
	 */
	this(this) @trusted
	{
		if (isInitialized(this))
		{
			static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).addRef)))
				__traits(getMember, this, uniqueMemberName!(T, "_data")).addRef();
			else static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).AddRef)))
				__traits(getMember, this, uniqueMemberName!(T, "_data")).AddRef();
			else static assert(0);
		}
	}
	
	/***************************************************************************
	 * 参照カウンタを減算し、カウンタが0になったら開放する
	 */
	~this() @trusted
	{
		if (isInitialized(this))
		{
			static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).release)))
				auto x = __traits(getMember, this, uniqueMemberName!(T, "_data")).release();
			else static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).Release)))
				auto x = __traits(getMember, this, uniqueMemberName!(T, "_data")).Release();
			static if (is(T == class) || is(T == interface))
			{
				if (!x)
				{
					if (auto obj = cast(Object)__traits(getMember, this, uniqueMemberName!(T, "_refData")))
						destroy(obj);
				}
			}
		}
	}
	
	/***************************************************************************
	 * 参照カウンタを保持してアタッチ＆加算する
	 */
	void opAssign(U)(U newRefData)
	if (is(U: RefType!T))
	{
		if (isInitialized(this))
		{
			static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).release)))
				auto x = __traits(getMember, this, uniqueMemberName!(T, "_data")).release();
			else static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).Release)))
				auto x = __traits(getMember, this, uniqueMemberName!(T, "_data")).Release();
			static if (is(T == class) || is(T == interface))
			{
				if (!x)
				{
					if (auto obj = cast(Object)__traits(getMember, this, uniqueMemberName!(T, "_data")))
						obj.destroy();
				}
			}
		}
		__traits(getMember, this, uniqueMemberName!(T, "_data")) = newRefData;
		if (isInitialized(this))
		{
			static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).addRef)))
				__traits(getMember, this, uniqueMemberName!(T, "_data")).addRef();
			static if (is(typeof(__traits(getMember, this, uniqueMemberName!(T, "_data")).AddRef)))
				__traits(getMember, this, uniqueMemberName!(T, "_data")).AddRef();
		}
	}
	
	/***************************************************************************
	 * 参照外し
	 */
	auto ref opUnary(string op)() if (op == "*")
	{
		return __traits(getMember, this, uniqueMemberName!(T, "_refData"));
	}
	
	/// alias thisで元データにアクセス可能
	mixin(`alias ` ~ uniqueMemberName!(T, "_refData") ~ ` this;`);
}
///
@safe unittest
{
	string[] msg;
	static class C
	{
		int cnt;
		string[]* msg;
		this(int x, string[]* m) {cnt = x; msg = m; }
		~this() @trusted {*msg ~= "dtor"; }
		int release() @trusted { cnt--; return cnt; }
		int addRef(){  cnt++; return cnt;}
	}
	
	{
		// コンストラクタを使うとカウント値が増える
		RefCounted!C dat1 = new C(0, (() @trusted => &msg)());
		assert(dat1.cnt == 1);
	}
	// スコープを抜けてRefCountedのインスタンスの寿命が終わると、デストラクタが呼ばれる
	assert(msg == ["dtor"]);
}



/***************************************************************************
 * 参照カウンタかどうか確認します
 */
enum isRefCounted(T) = isInstanceOf!(RefCounted, T);
///
@safe unittest
{
	static assert(isRefCounted!(RefCounted!int));
	static assert(!isRefCounted!(int*));
}

/***************************************************************************
 * 参照カウンタの元データの型を得ます
 */
template RefCountedTypeOf(T)
if (isRefCounted!T)
{
	alias RefCountedTypeOf = TemplateArgsOf!(T)[0];
}
///
@safe unittest
{
	static assert(is(RefCountedTypeOf!(RefCounted!int) == int));
}

/***************************************************************************
 * 参照が初期化されているか確認する
 */
bool isInitialized(T)(const ref RefCounted!T dat)
{
	static if (__traits(compiles, __traits(getMember, dat, uniqueMemberName!(T, "_data")) ? true : false))
	{
		// ifで評価可能
		return __traits(getMember, dat, uniqueMemberName!(T, "_data")) ? true : false;
	}
	else static if (__traits(compiles, __traits(getMember, dat, uniqueMemberName!(T, "_data")) !is null))
	{
		// is nullで比較可能
		return __traits(getMember, dat, uniqueMemberName!(T, "_data")) !is null;
	}
	else static if (__traits(compiles, __traits(getMember, dat, uniqueMemberName!(T, "_data")) !is T.init))
	{
		// is T.initで比較可能
		return __traits(getMember, dat, uniqueMemberName!(T, "_data")) !is T.init;
	}
	else static assert(0);
}
/// ditto
bool isEmpty(T)(const ref RefCounted!T dat)
{
	return !isInitialized(dat);
}
/// ditto
alias isNull = isEmpty;
///
@safe unittest
{
	RefCounted!int x;
	assert(!x.isInitialized());
	assert(x.isEmpty());
	assert(x.isNull());
	x = createRefCounted!int(1);
	assert(x.isInitialized());
	assert(!x.isEmpty());
	assert(!x.isNull());
}

/***************************************************************************
 * 参照カウンタ加算せずにアタッチする
 */
void attach(T, U)(ref RefCounted!T rc, auto ref U newRefData) pure nothrow @property
if (is(U: RefType!T))
{
	__traits(getMember, rc, uniqueMemberName!(T, "_data")) = newRefData;
	if (__traits(isRef, newRefData))
		newRefData = null;
}
///
@safe unittest
{
	static class C
	{
		int cnt;
		this(int x) {cnt = x;}
		int release() @trusted { cnt--; return cnt; }
		int addRef(){  cnt++; return cnt;}
	}
	
	// コンストラクタを使うとカウント値が増える
	RefCounted!C dat1 = new C(1);
	assert(dat1.cnt == 2);
	dat1.release();
	
	// attachを使うとカウント値が増えない
	RefCounted!C dat2;
	dat2.attach(new C(1));
	assert(dat2.cnt == 1);
}

/***************************************************************************
 * 参照外し
 */
pragma(inline) ref inout(T) deref(T)(inout ref RefCounted!T rc) pure nothrow
{
	return __traits(getMember, rc, uniqueMemberName!(T, "_refData"));
}
///
@safe unittest
{
	auto x = createRefCounted!int(1);
	static assert (is(typeof(x.deref) == int));
	x.deref = 2;
	assert(x == 2);
}


/***************************************************************************
 * ポインタを得る
 */
pragma(inline) inout(T)* ptr(T)(inout ref RefCounted!T rc) pure nothrow
{
	return &deref(rc);
}
///
@safe unittest
{
	auto x = createRefCounted!int(1);
	static assert (is(typeof(x.ptr) == int*));
	*x = 2;
	assert(x == 2);
	(() @trusted => *(x.ptr) = 3)();
	assert(x == 3);
}

/*******************************************************************************
 * 参照カウンタを生成
 */
RefCounted!T createRefCounted(T, Args...)(auto ref Args args) @trusted
if (isRefCounted!T)
{
	return createRefCounted!(RefCountedTypeOf!T)(args);
}
/// ditto
RefCounted!T createRefCounted(T, Args...)(auto ref Args args) @trusted
if (is(T == class) && isCountedData!T)
{
	return attachRefCounted!T(new T(args));
}
/// ditto
RefCounted!T createRefCounted(T, Args...)(auto ref Args args) @trusted
if (!isPointer!T && (is(T == struct) || is(T == union)) && isCountedData!T)
{
	return attachRefCounted!T(T(args));
}
/// ditto
RefCounted!T createRefCounted(T, Args...)(auto ref Args args) @trusted
if (isPointer!T && (is(PointerTarget!T == struct) || is(PointerTarget!T == union)) && isCountedData!T)
{
	alias Inst = PointerTarget!T;
	return attachRefCounted!T(new Inst(args));
}
/// ditto
RefCounted!T createRefCounted(T, Args...)(auto ref Args args) @trusted
if (!isCountedData!T)
{
	import std.conv: emplace;
	CountedData!T ret;
	static assert(is(RefType!T == CountedData!T));
	ret._impl.initializeCountedInstance();
	emplace!T(cast(void[])ret._impl.buffer, args);
	return ret.attachRefCounted!T();
}
/// ditto
RefCounted!T createRefCounted(T, alias allocator, Args...)(auto ref Args args) @trusted
if (!isCountedData!T && isAllocator!allocator)
{
	CountedData!T ret;
	ret._impl.initializeCountedInstance(allocator);
	return ret.attachRefCounted!T();
}

///
@system unittest
{
	enum short initCnt = 1;
	// class
	static class C
	{
		short cnt;
		this(int x) {cnt = 1;}
		int release(){ cnt--; return cnt; }
		int addRef(){  cnt++; return cnt;}
	}
	auto c = createRefCounted!C(1);
	auto c2 = c;
	assert(c.cnt == 2);
	
	// struct
	static struct S
	{
		short cnt;
		int release(){ cnt--; return cnt; }
		int addRef(){  cnt++; return cnt;}
	}
	// struct - for pointer
	auto s1 = createRefCounted!(S*)(initCnt);
	assert(s1.cnt == 1);
	static assert(isCountedData!(S*));
	// struct - for CountedData
	auto s2 = createRefCounted!S(initCnt);
	auto s3 = s1;
	assert(s1.cnt == 2);
	auto s4 = s2;
	// s2, s4はCountedDataなので、インスタンスの中身ではなく
	// CountedDataのcounterが増加する
	assert(s2.cnt == 1);
	assert(s2.counter == 2);
	
	// for union
	static union U
	{
		short cnt;
		int release(){ cnt--; return cnt; }
		int addRef(){  cnt++; return cnt;}
	}
	auto u1 = createRefCounted!(U*)(initCnt);
	assert(u1.cnt == 1);
	static assert(isCountedData!(U*));
	auto u2 = createRefCounted!U(initCnt);
	assert(u2.cnt == 1);
	auto u3 = u1;
	assert(u1.cnt == 2);
	auto u4 = u2;
	// u2, u4はCountedDataなので、インスタンスの中身ではなく
	// CountedDataのcounterが増加する
	assert(u2.cnt == 1);
	assert(u2.counter == 2);
	
	// for scalar data
	auto int1 = createRefCounted!int(1);
	
	// with allocator
	auto long1 = createRefCounted!(long, defaultAllocatorByGC(long.sizeof))(1);
	
}

/*******************************************************************************
 * 参照カウンタを追加せずにRefCountedを得る
 */
RefCounted!T attachRefCounted(T)(T newRefData)
if (isCountedData!T)
{
	import voile.misc: assumeNogc;
	return assumeNogc!(attachRefCountedImpl!T)(&newRefData);
}
/// ditto
RefCounted!T attachRefCounted(T)(RefType!T newRefData)
if (!isCountedData!T)
{
	import voile.misc: assumeNogc;
	return assumeNogc!(attachRefCountedImpl!T)(&newRefData);
}
private RefCounted!T attachRefCountedImpl(T)(void* newRefData)
{
	import std.algorithm: move;
	return move(*cast(RefCounted!T*)newRefData);
}

version (Windows) @system unittest
{
	import core.sys.windows.com, std.stdio;
	IUnknown x;
	RefCounted!IUnknown dat;
	dat = x;
	dat = dat;
}
@system unittest
{
	int a;
	
	class XXX
	{
		int cnt;
		int release(){ a = 1; cnt--;return cnt; }
		int addRef(){ a = 2; cnt++; return cnt;}
	}
	assert(a == 0);
	RefCounted!XXX dat2 = new XXX;
	assert(dat2.cnt == 1);
	assert(a == 2);
	{
		RefCounted!XXX dat3 = dat2;
		assert(a == 2);
		assert(dat3.cnt == 2);
		dat2 = dat3;
		assert(a == 1);
		assert(dat3.cnt == 2);
	}
	assert(a == 1);
	assert(dat2.cnt == 1);
}

private ref inout(CountedData!T) getCountedData(T)(inout ref RefCounted!T rc) @safe @nogc pure nothrow @property
if (!isCountedData!T || isInstanceOf!(CountedData, T))
{
	static assert(is(typeof(__traits(getMember, rc, uniqueMemberName!(T, "_data"))) == inout(CountedData!T)));
	return __traits(getMember, rc, uniqueMemberName!(T, "_data"));
}


/***************************************************************************
 * バッファ領域へアクセス
 * 
 * バッファ領域は、Tのインスタンスと拡張領域のメモリ領域全体を指す。
 * 
 * Note:
 *      release後に触れた場合、ダングリングポインタへのアクセスの可能性がある。
 *      また、書き換えた場合、本来RefCountedで管理しているデータが損失する可能性がある。
 */
inout(ubyte)[] buffer(T)(inout ref RefCounted!T rc) @system @nogc pure nothrow @property
if (!isCountedData!T || isInstanceOf!(CountedData, T))
in (getCountedData(rc)._instance)
{
	return getCountedData(rc).buffer;
}
///
@system unittest
{
	auto dat = createRefCounted!int(1);
	assert(dat.buffer.length == 4);
	assert(dat == *cast(int*)dat.buffer.ptr);
}

/***************************************************************************
 * 拡張データ領域へアクセス
 * 
 * 初期化時にTのインスタンスより大きなバッファを与えることで、拡張データ領域を持つことができる。
 * この関数は拡張データ領域へのアクセス手段を提供する。
 * 
 * Note:
 *      release後に触れた場合、ダングリングポインタへのアクセスの可能性がある。
 *      また、書き換えた場合、本来RefCountedで管理しているデータが損失する可能性がある。
 */
inout(ubyte)[] extraBuffer(T)(inout ref RefCounted!T rc) @system @nogc pure nothrow @property
if (!isCountedData!T || isInstanceOf!(CountedData, T))
in (getCountedData(rc)._instance)
in (getCountedData(rc)._instance.rawData.length >= T.sizeof)
{
	return getCountedData(rc).extra();
}
///
@system unittest
{
	auto dat = createRefCounted!(int, defaultAllocatorByMalloc(int.sizeof + 4))(1);
	assert(dat.buffer.length == 8);
	assert(dat.extraBuffer.length == 4);
}

/***************************************************************************
 * カウント値を得る
 */
int counter(T)(const ref RefCounted!T rc) @safe @nogc pure nothrow @property
if (!isCountedData!T || isInstanceOf!(CountedData, T))
in (getCountedData(rc)._instance)
in (getCountedData(rc)._instance.rawData.length >= T.sizeof)
{
	return getCountedData(rc)._instance.counter;
}
///
@system unittest
{
	auto dat1 = createRefCounted!int(1);
	assert(dat1.counter == 1);
	{
		auto dat2 = dat1;
		assert(dat1.counter == 2);
	}
	assert(dat1.counter == 1);
}
