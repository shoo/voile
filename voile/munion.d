/*******************************************************************************
 * 管理された共用体を提供する
 */
module voile.munion;

import std.meta;
import std.traits;
public import voile.attr: ignore, hasIgnore;

private pragma(inline)
{
	
	void _moveImplA(T)(ref T src, ref T dst)
	{
		import std.algorithm;
		move(src, dst);
	}
	
	void _move(T)(ref T src, ref T dst) pure @nogc nothrow @trusted
	{
		(cast(void function(ref T, ref T) pure @nogc nothrow @trusted)(&_moveImplA!T))(src, dst);
	}
	
	
	T _moveImplB(T)(ref T src)
	{
		import std.algorithm;
		return move(src);
	}
	T _move(T)(ref T src) pure @nogc nothrow @trusted
	{
		return (cast(T function(ref T) pure @nogc nothrow @trusted)(&_moveImplB!T))(src);
	}
	
	
	void _initializeImpl(T)(ref T src)
	{
		import std.conv: emplace;
		emplace(&src);
	}
	void _initialize(T)(ref T src) pure @nogc nothrow @trusted
	{
		static if (hasNested!T)
		{
			static foreach (m; FieldNameTuple!T)
				_initialize(__traits(getMember, src, m));
		}
		else
		{
			(cast(void function(ref T) pure @nogc nothrow @trusted)(&_initializeImpl!T))(src);
		}
	}
	
	
	void _emplaceImpl(T, Args...)(ref T src, ref Args args)
	{
		import std.conv: emplace;
		emplace(&src, args);
	}
	void _emplace(T, Args...)(ref T src, ref Args args) pure @nogc nothrow @trusted
	{
		(cast(void function(ref T, ref Args) pure @nogc nothrow @trusted)(&_emplaceImpl!(T, Args)))(src, args);
	}
	
	
	void _memcpy(T)(ref T src, ref T dst) pure @nogc nothrow @trusted
	{
		(cast(ubyte*)&dst)[0..T.sizeof] = (cast(ubyte*)&src)[0..T.sizeof];
	}
	
	auto _unionCtor(Union, size_t idx, Args...)(auto ref Args args) pure @nogc nothrow @trusted
	if (is(Union == union) && idx < FieldNameTuple!Union.length)
	{
		Union ret = void;
		_emplace(ret.tupleof[idx], args);
		return ret;
	}
	
	auto _unionInit(Union, size_t idx)(auto ref Fields!Union[idx] val) pure @nogc nothrow @trusted
	if (is(Union == union) && idx < FieldNameTuple!Union.length)
	{
		alias T = Fields!Union[idx];
		Union ret = void;
		(cast(ubyte*)&ret.tupleof[idx])[0..T.sizeof] = (cast(ubyte*)&val)[0..T.sizeof];
		return ret;
	}
}

version (unittest) private import std.datetime: Date;

@safe unittest
{
	union U {
		int a;
		int b;
	}
	U u;
	u = _unionInit!(U, 1)(1);
}


private mixin template ManagedUnionImpl(Instance, tags...)
if (is(Instance == union) && (Fields!Instance.length == tags.length || tags.length == 0))
{
	private template GetIndexType(size_t typecnt)
	{
		static if (typecnt < ubyte.max)
		{
			alias GetIndexType = ubyte;
		}
		else static if (typecnt < ushort.max)
		{
			alias GetIndexType = ushort;
		}
		else static if (typecnt < uint.max)
		{
			alias GetIndexType = uint;
		}
		else static if (typecnt < ulong.max)
		{
			alias GetIndexType = ulong;
		}
		else static assert(0, "Unsupported type counts.");
	}
	alias IndexType = GetIndexType!(FieldNameTuple!Instance.length);
	
	static if (tags.length == 0)
		alias TagType = IndexType;
	else
		alias TagType = typeof(tags[0]);
	
	enum IndexType memberCount = FieldNameTuple!Instance.length;
	alias MemberTypes = Fields!Instance;
	
	enum bool hasDestructor = anySatisfy!(hasElaborateDestructor, MemberTypes);
	enum bool hasNestedData = anySatisfy!(hasNested, MemberTypes);
	static if (tags.length == 0)
	{
		enum TagType getTag(IndexType idx) = cast(TagType)idx;
		enum IndexType getIndex(TagType t) = cast(IndexType)t;
	}
	else
	{
		enum TagType getTag(IndexType idx) = tags[idx];
		enum IndexType getIndex(TagType t) = staticIndexOf!(t, tags);
	}
	
	enum TagType notfoundTag = TagType.max;
	
	TagType  _tag = notfoundTag;
	Instance _inst;
	
	/***************************************************************************
	 *
	 */
	private this()(auto ref Instance inst)
	{
		_inst = inst;
	}
	
	/***************************************************************************
	 *
	 */
	private this()(auto ref Instance inst, TagType t)
	{
		_inst = inst;
		_tag  = t;
	}
	
	static if (hasDestructor)
	{
		// 型のうちいずれかがデストラクタを持つ場合、対処する
		public ~this()
		{
			final switch (_tag)
			{
				static foreach (i, T; MemberTypes)
				{
				case i:
					static if (hasElaborateDestructor!T)
						_inst.tupleof[i]._move();
					return;
				}
				case notfoundTag:
					return;
			}
		}
	}
	
	/***************************************************************************
	 * タグ
	 */
	TagType tag() nothrow pure @nogc @safe const @property
	{
		return _tag;
	}
	
	/***************************************************************************
	 * 初期化する
	 */
	void initialize(TagType t, Args...)(auto ref Args args)
	if (getIndex!t < memberCount)
	{
		static if (hasDestructor)
			clear();
		_emplace(_inst.tupleof[getIndex!t], args);
		_tag = t;
	}
	
	/***************************************************************************
	 * データをセットする
	 */
	void set(TagType t)(auto ref MemberTypes[getIndex!t] val) @property
	if (getIndex!t < memberCount)
	{
		static if (hasDestructor)
			clear();
		initialize!t(val);
		static if (is(MemberTypes[getIndex!t] == struct)
			&& hasElaborateDestructor!(MemberTypes[getIndex!t])
			&& !__traits(isRef, val))
			_initialize(val);
	}
	
	/***************************************************************************
	 * データを取得する
	 */
	auto ref get(TagType t)() nothrow pure @nogc inout @property
	if (getIndex!t < memberCount)
	in (t == _tag)
	{
		return _inst.tupleof[getIndex!t];
	}
	
	/***************************************************************************
	 * データがセットされているかチェックする
	 */
	bool check(TagType t)() nothrow pure @nogc @safe const
	if (getIndex!t < memberCount)
	{
		return _tag == t;
	}
	
	/***************************************************************************
	 * 何もデータが入っていないか確認する
	 */
	bool empty() nothrow pure @nogc @safe const @property
	{
		return _tag == notfoundTag;
	}
	
	/***************************************************************************
	 * データをクリアする
	 */
	void clear()()
	{
		this._move();
		_tag = notfoundTag;
	}
}

/*******************************************************************************
 * タグ付き共用体
 */
struct ManagedUnion(Types...)
if (Types.length > 0 && NoDuplicates!Types.length == Types.length)
{
private:
	
	enum bool isManagedUnion = Types.length == 1 && is(Types[0] == union);
	
	static if (isManagedUnion)
	{
		alias FieldTypes = Fields!(Types[0]);
	}
	else
	{
		alias FieldTypes = Types;
	}
	
	
	static if (isManagedUnion)
	{
		alias Instance = Types[0];
	}
	else
	{
		union Instance
		{
			mixin template DefineMember(T)
			{
				T _value;
			}
			static foreach (T; FieldTypes)
				mixin DefineMember!T;
		}
	}
	mixin ManagedUnionImpl!Instance _impl;
	
	template WithType()
	{
		template TargetTypeInfo(T)
		{
			enum IndexType typeIndex = cast(IndexType)staticIndexOf!(T, MemberTypes);
			enum bool hasType        = typeIndex != notfoundTag;
			static if (hasType)
			{
				enum bool      isAssignable    = true;
				enum IndexType assignableIndex = typeIndex;
			}
			else
			{
				enum bool _isImplicitlyConvertible(U) = isImplicitlyConvertible!(T, U);
				enum IndexType assignableIndex        = cast(IndexType)staticIndexOf!(true,
				                                        staticMap!(_isImplicitlyConvertible, MemberTypes));
				enum bool isAssignable                = assignableIndex != notfoundTag;
			}
		}
		///
		alias hasType(T)            = TargetTypeInfo!T.hasType;
		///
		alias getTypeIndex(T)       = TargetTypeInfo!T.typeIndex;
		///
		alias isAssignable(T)       = TargetTypeInfo!T.isAssignable;
		///
		alias getAssignableIndex(T) = TargetTypeInfo!T.assignableIndex;
		
		
		/***********************************************************************
		 * 初期化する
		 */
		void initialize(T, Args...)(auto ref Args args)
		if (hasType!T && !isManagedUnion)
		{
			static if (hasDestructor)
				clear();
			enum idx = getTypeIndex!T;
			_emplace(_inst.tupleof[idx], args);
			_tag = idx;
		}
		
		/***********************************************************************
		 * データをセットする
		 */
		void set(T)(auto ref T val) @property
		if (isAssignable!T && !isManagedUnion)
		{
			enum idx = getAssignableIndex!T;
			static if (hasDestructor)
				clear();
			initialize!T(val);
			//_memcpy(val, _inst.tupleof[idx]);
			//_tag = idx;
			static if (is(T == struct) && hasElaborateDestructor!T && !__traits(isRef, val))
				_initialize(val);
		}
	
		/***********************************************************************
		 * データを取得する
		 */
		auto ref get(T)() nothrow pure @nogc inout @property
		if (hasType!T && !isManagedUnion)
		in (getTag!(getAssignableIndex!T) == _tag)
		{
			enum idx = getAssignableIndex!T;
			return _inst.tupleof[idx];
		}
		
		/***********************************************************************
		 * データがセットされているかチェックする
		 */
		bool check(T)() nothrow pure @nogc @safe const
		if (hasType!T && !isManagedUnion)
		{
			return _tag == getTag!(getTypeIndex!T);
		}
	}
	mixin WithType _implT;
public:
	
	/***************************************************************************
	 * コンストラクタ
	 */
	this(T)(auto ref T val)
	if (isAssignable!T)
	{
		enum idx = getAssignableIndex!T;
		static if (__traits(isRef, val))
			_inst.tupleof[idx] = val;
		else
			_inst.tupleof[idx] = val._move();
		_tag = idx;
	}
	
	/***************************************************************************
	 * 代入
	 */
	void opAssign(T)(auto ref T val)
	if (isAssignable!T && !isManagedUnion)
	{
		static if (hasDestructor)
			clear();
		enum idx = getAssignableIndex!T;
		initialize!idx(val);
		static if (is(T == struct) && hasElaborateDestructor!T && !__traits(isRef, val))
			_initialize(val);
	}
	
	/***************************************************************************
	 * キャスト
	 */
	inout(T) opCast(T)() inout
	if (isAssignable!T && !isManagedUnion)
	{
		return _implT.get!T();
	}
	
	/***************************************************************************
	 * 名前アクセス
	 * 
	 * ManagedUnionの引数に共用体を与えた場合は名前でのアクセスを許可する。
	 * See_Also: $(D $(LINK2 _voile--_voile.munion.html#.Managed, Managed))
	 */
	auto ref opDispatch(string member)()
	if (isManagedUnion && hasMember!(Instance, member))
	{
		return get!(staticIndexOf!(member, FieldNameTuple!(Instance)));
	}
	/// ditto
	void opDispatch(string member)(auto ref MemberTypes[staticIndexOf!(member, FieldNameTuple!(Instance))] val)
	if (isManagedUnion && hasMember!(Instance, member))
	{
		set!(staticIndexOf!(member, FieldNameTuple!(Instance)))(val);
	}
}

///
@safe pure nothrow @nogc unittest
{
	alias U = ManagedUnion!(int, string);
	U dat;
	// assign
	dat = 1;
	dat = U("foo");
	dat.initialize!int(1);
	
	// cast
	assert(cast(int)dat == 1);
	
	// check
	assert(!dat.empty);
	assert(dat.check!int);
	assert(!dat.check!string);
	assert(dat.check!0);
	assert(!dat.check!1);
	
	// getter/setter
	assert(dat.tag == 0);
	assert(dat.get!int == 1);
	dat.set!int = 5;
	assert(dat.get!int == 5);
	dat.set!1 = "foo";
	assert(dat.get!1 == "foo");
	
	// clear
	dat.clear();
	assert(dat.empty);
	
	// match
	dat = "foo";
	assert(dat.match!(
		(int x)      => x,
		(string str) => str.length) == "foo".length);
}

@safe pure @nogc nothrow unittest
{
	import std.exception;
	import std.conv: ConvException;
	alias U = ManagedUnion!(int, short, long);
	U dat = 1;
	assert(dat.check!int);
	assert(!dat.check!short);
	assert(!dat.check!long);
	assert(dat.check!0);
	assert(!dat.check!1);
	assert(!dat.check!2);
	static assert(!__traits(compiles, dat.check!double));
	static assert(!__traits(compiles, dat.check!10));
	static assert(!__traits(compiles, dat.check!10000));
	assert(dat.get!int == 1);
	dat.set!long = 10;
	assert(dat.get!2 == 10);
	dat.set!0 = 1;
}


/*******************************************************************************
 * 共用体に管理機能を付与する
 */
template Managed(T)
if (is(T == union))
{
	alias Managed = ManagedUnion!T;
	static assert(Managed.isManagedUnion);
}

///
@safe unittest
{
	union U
	{
		uint   x;
		uint   y;
		string str;
	}
	
	alias MU = ManagedUnion!U;
	
	MU dat;
	
	dat.x = 10;
	assert(dat.tag == 0);
	assert(dat.x == 10);
	assert(dat.get!0 == 10);
	dat.str = "xxx";
	assert(dat.get!2 == "xxx");
	assert(dat.str == "xxx");
}




/*******************************************************************************
 * データ付きのenum
 */
struct Endata(E)
{
private:
	mixin template Impl()
	{
		union Instance
		{
			static foreach (m; __traits(allMembers, E))
			{
				static if (hasData!(__traits(getMember, E, m)))
					mixin(`DataType!(__traits(getMember, E, m)) ` ~ m ~ `;`);
			}
		}
		alias tags = Filter!(hasData, EnumMembers!E);
		mixin ManagedUnionImpl!(Instance, tags);
		alias memberNames = FieldNameTuple!Instance;
		enum TagType getTag(string member) = __traits(getMember, E, member);
		alias MemberType(string member) = MemberTypes[staticIndexOf!(member, memberNames)];
	}
	mixin Impl _impl;
	
public:
	
	/***********************************************************************
	 * 
	 */
	static foreach (m; memberNames)
	{
		mixin(`
			auto ref `~m~`()() @property
			{
				return _impl.get!(_impl.getTag!"`~m~`")();
			}
			void `~m~`()(auto ref _impl.MemberType!"`~m~`" val) @property
			{
				return _impl.set!(_impl.getTag!"`~m~`")(val);
			}
		`);
	}
}


///
@safe pure nothrow @nogc unittest
{
	enum E
	{
		@data!int     id,
		ignored,
		@data!string  str,
		@data!int     number,
		@data!string  get,
	}
	mixin EnumMemberAlieses!E;
	
	alias EnumData = Endata!E;
	EnumData dat;
	
	// assign
	dat.initialize!str("test");
	dat.number = 10;
	
	// check
	assert(!dat.empty);
	assert(dat.check!number);
	assert(!dat.check!str);
	
	// getter/setter
	assert(dat.tag == number);
	assert(.get!number(dat) == 10);
	dat.set!id = 5;
	assert(dat.tag == id);
	
	// clear
	dat.clear();
	assert(dat.empty);
	
	// ignored member
	static assert(!__traits(compiles, dat.set!ignore(0)));
	
	// 
	dat.id = 100;
	assert(dat.match!(
		(Data!id x) => x + 11,
		()          => 10) == 111);
	assert(dat.match!(
		(Data!number x) => x + 11,
		()              => 10) == 10);
	
}

@safe pure nothrow unittest
{
	import std.exception;
	enum E
	{
		@data!int     id,
		ignored,
		@data!string  str,
		@data!int     number,
		@data!string  get,
	}
	
	mixin EnumMemberAlieses!E;
	
	static assert(hasData!id);
	static assert(hasData!str);
	static assert(hasData!number);
	
	alias EnumData = Endata!E;
	EnumData dat;
	
	static assert(dat._impl.getTag!"number" == number);
	static assert(is(dat._impl.MemberType!"number" == int));
	
	dat.number = 10;
	assert(dat.tag == number);
	assert(dat.number == 10);
	
	set!id(dat, 1);
	assert(tag(dat) == id);
	assert(check!id(dat));
	assert(.get!id(dat) == 1);
	clear(dat);
	assert(empty(dat));
	initialize!(E.get)(dat, "test");
	assert(tag(dat) == E.get);
	assert(dat.get == "test");
	
	
	assert(dat.match!(
		(Data!id x) => 0,
		() => 10) == 10);
	
	import voile.misc: nogcEnforce;
	assert(dat.match!(
		(Data!get x)  => nogcEnforce(0),
		(Exception x) => 5,
		()            => 10) == 5);
}


/*******************************************************************************
 * ManagedUnionのタグ型を得る
 */
template TagType(MU)
if (isInstanceOf!(ManagedUnion, MU) || isInstanceOf!(Endata, MU))
{
	alias TagType = MU._impl.TagType;
}

///
@safe unittest
{
	static assert(is(TagType!(ManagedUnion!(int, string)) == ubyte));
}

/*******************************************************************************
 * 有効なタグか確認する
 */
template isAvailableTag(MU, alias tag)
if (isInstanceOf!(ManagedUnion, MU) || isInstanceOf!(Endata, MU))
{
	static if (!isType!tag && isOrderingComparable!(CommonType!(typeof(tag), TagType!MU)))
	{
		enum bool isAvailableTag = MU._impl.getIndex!tag < MU._impl.memberCount;
	}
	else
	{
		enum bool isAvailableTag = false;
	}
}

///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	static assert( isAvailableTag!(MU, 1));
	static assert(!isAvailableTag!(MU, 2));
}

/*******************************************************************************
 * 有効なタグか確認する
 */
template getNotFoundTag(MU)
if (isInstanceOf!(ManagedUnion, MU) || isInstanceOf!(Endata, MU))
{
	enum MU._impl.TagType getNotFoundTag = MU._impl.notfoundTag;
}

///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	static assert(getNotFoundTag!MU == ubyte.max);
}

/*******************************************************************************
 * 型を持っているか確認する
 */
template hasType(MU, T)
if (isInstanceOf!(ManagedUnion, MU))
{
	enum bool hasType = MU._implT.hasType!T;
}

///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	static assert(hasType!(MU, int));
	static assert(hasType!(MU, string));
	static assert(!hasType!(MU, long));
}


/*******************************************************************************
 * タグを確認する
 */
TagType!MU tag(MU)(in auto ref MU tu)
if (isInstanceOf!(ManagedUnion, MU))
{
	return tu._impl._tag;
}
///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	MU tu;
	assert(tag(tu) == getNotFoundTag!MU);
	tu = 1;
	assert(tag(tu) != getNotFoundTag!MU);
	assert(tag(tu) == 0);
	tu = "1";
	assert(tag(tu) != getNotFoundTag!MU);
	assert(tag(tu) == 1);
}

/*******************************************************************************
 * 初期化する
 */
void initialize(alias tag, MU, Args...)(auto ref MU dat, auto ref Args args)
if (isInstanceOf!(ManagedUnion, MU) && isAvailableTag!(MU, tag))
{
	dat._impl.initialize!tag(args);
}
/// ditto
void initialize(T, MU, Args...)(auto ref MU dat, auto ref Args args)
if (isInstanceOf!(ManagedUnion, MU) && hasType!(MU, T))
{
	dat._implT.initialize!T(args);
}
/// ditto
void initialize(alias tag, E, Args...)(auto ref Endata!E e, auto ref Args args)
{
	e._impl.initialize!tag(args);
}
///
@safe unittest
{
	struct S { int x; }
	alias MU = ManagedUnion!(int, S);
	MU tu;
	initialize!0(tu, 1);
	assert(get!0(tu) == 1);
	initialize!1(tu, 100);
	assert(get!1(tu) == S(100));
	// for type
	initialize!int(tu, 1000);
	assert(get!0(tu) == 1000);
}
///
@safe unittest
{
	import std.datetime: Date;
	enum E { @data!int x, @data!Date date }
	mixin EnumMemberAlieses!E;
	
	alias ED = Endata!E;
	ED e;
	initialize!x(e, 1);
	assert(get!x(e) == 1);
	initialize!date(e, Date(2020, 8, 5));
	assert(get!date(e) == Date(2020, 8, 5));
}


/*******************************************************************************
 * データをセットする
 */
void set(alias tag, MU, T)(ref auto MU dat, auto ref T val)
if (isInstanceOf!(ManagedUnion, MU) && isAvailableTag!(MU, tag))
{
	dat._impl.set!tag(val);
}
/// ditto
void set(T, MU)(ref auto MU dat, auto ref T val)
if (isInstanceOf!(ManagedUnion, MU) && hasType!(MU, T))
{
	dat._implT.set!T(val);
}
///
@safe unittest
{
	struct S { int x; }
	alias MU = ManagedUnion!(int, S);
	MU tu;
	set!0(tu, 1);
	assert(get!0(tu) == 1);
	set!1(tu, S(100));
	assert(get!1(tu) == S(100));
	// for type
	set!int(tu, 10);
	assert(get!0(tu) == 10);
}

/*******************************************************************************
 * データを取得する
 */
auto ref get(alias tag, MU)(inout auto ref MU dat)
if (isInstanceOf!(ManagedUnion, MU) && isAvailableTag!(MU, tag))
{
	return dat._impl.get!tag();
}
/// ditto
auto ref get(T, MU)(inout auto ref MU dat)
if (isInstanceOf!(ManagedUnion, MU) && hasType!(MU, T))
{
	return dat._implT.get!T();
}
///
@safe unittest
{
	import core.exception: AssertError;
	import std.exception;
	alias MU = ManagedUnion!(int, string);
	MU tu;
	(() @trusted => assertThrown!AssertError(get!0(tu) == 1) )();
	set!1(tu, "test");
	assert(get!1(tu) == "test");
	// for type
	assert(get!string(tu) == "test");
}

/*******************************************************************************
 * データが入っていることを確認する
 */
bool check(alias tag, MU)(in auto ref MU dat)
if (isInstanceOf!(ManagedUnion, MU) && isAvailableTag!(MU, tag))
{
	return dat._impl.check!tag();
}
/// ditto
bool check(T, MU)(in auto ref MU dat)
if (isInstanceOf!(ManagedUnion, MU) && hasType!(MU, T))
{
	return dat._implT.check!T();
}
///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	MU tu;
	assert(!check!0(tu));
	assert(!check!1(tu));
	set!1(tu, "test");
	assert(!check!0(tu));
	assert(check!1(tu));
	// for type
	assert(check!string(tu));
}

/*******************************************************************************
 * データをクリアする
 */
void clear(MU)(auto ref MU dat)
if (isInstanceOf!(ManagedUnion, MU))
{
	dat._impl.clear();
}
///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	MU tu;
	assert(!check!0(tu));
	assert(!check!1(tu));
	set!1(tu, "test");
	assert(!check!0(tu));
	assert(check!1(tu));
	clear(tu);
	assert(!check!0(tu));
	assert(!check!1(tu));
}

/*******************************************************************************
 * データがクリアされているか確認する
 */
bool empty(MU)(in auto ref MU dat)
if (isInstanceOf!(ManagedUnion, MU))
{
	return dat._impl.empty();
}
///
@safe unittest
{
	alias MU = ManagedUnion!(int, string);
	MU tu;
	assert(empty(tu));
	set!1(tu, "test");
	assert(!empty(tu));
}




/*******************************************************************************
 * 
 */
Endata!E.TagType tag(E)(in auto ref Endata!E e)
{
	return e._impl._tag;
}


/*******************************************************************************
 * 
 */
void set(alias tag, E, T)(ref auto Endata!E e, auto ref T val)
{
	e._impl.set!tag(val);
}

/*******************************************************************************
 * 
 */
auto ref get(alias tag, E)(inout auto ref Endata!E e)
{
	return e._impl.get!tag();
}

/*******************************************************************************
 * 
 */
bool check(alias tag, E)(in auto ref Endata!E e)
{
	return e._impl.check!tag();
}

/*******************************************************************************
 * 
 */
void clear(E)(auto ref Endata!E e)
{
	e._impl.clear();
}

/*******************************************************************************
 * 
 */
bool empty(E)(in auto ref Endata!E e)
{
	return e._impl.empty();
}





@safe unittest
{
	import std;
	static string[] msgDtor;
	string[] msgRelease;
	void msgClear()
	{
		msgDtor = null;
		msgRelease = null;
	}
	struct A
	{
		int x;
		~this()
		{
			msgDtor ~= "A";
			if (x)
				msgRelease ~= "A";
		}
	}
	struct B
	{
		int x;
		this(int v) {x = v;}
		~this()
		{
			msgDtor ~= "B";
			if (x)
				msgRelease ~= "B";
		}
	}
	union U
	{
		A a;
		B b;
	}
	alias AB = ManagedUnion!(A, B);
	
	{
		U u;
	}
	
	assert(msgDtor.length == 0);
	assert(msgRelease.length == 0);
	
	{
		AB o = A(1);
		assert(msgDtor == ["A"]);
		assert(msgRelease == []);
	}
	assert(msgDtor == ["A", "A"]);
	assert(msgRelease == ["A"]);
	
	msgClear();
	{
		AB o = B(1);
		assert(msgDtor == ["B"]);
		assert(msgRelease == []);
		o = A(1);
		assert(msgDtor == ["B", "B", "A"]);
		assert(msgRelease == ["B"]);
	}
	assert(msgDtor == ["B", "B", "A", "A"]);
	assert(msgRelease == ["B", "A"]);
	
	msgClear();
	struct C
	{
		A a;
		int x;
		this(int v)
		{
			a = A(v);
			x = v;
		}
		~this()
		{
			msgDtor ~= "C";
			if (x)
				msgRelease ~= "C";
		}
	}
	alias AC = ManagedUnion!(A, C);
	{
		AC o = A(1);
		assert(msgDtor == ["A"]);
		assert(msgRelease == []);
		o = C(1);
		assert(msgDtor == ["A", "A", "C", "A"]);
		assert(msgRelease == ["A"]);
	}
	assert(msgDtor == ["A", "A", "C", "A", "C", "A"]);
	assert(msgRelease == ["A", "C", "A"]);
	
	msgClear();
	{
		AC o;
		o.set!0 = A(1);
		assert(msgDtor == ["A"]);
		assert(msgRelease == []);
		o.set!C = C(1);
		assert(msgDtor == ["A", "A", "C", "A"]);
		assert(msgRelease == ["A"]);
	}
	assert(msgDtor == ["A", "A", "C", "A", "C", "A"]);
	assert(msgRelease == ["A", "C", "A"]);
	
	
	msgClear();
	static struct D
	{
		string[]* msgRelease;
		this(ref string[] a) @trusted
		{
			msgRelease = &a;
		}
		~this()
		{
			msgDtor ~= "D";
			if (msgRelease)
				*msgRelease ~= "D";
		}
	}
	static struct E
	{
		string[]* msgRelease;
		~this() @safe
		{
			msgDtor ~= "E";
			if (msgRelease)
				*msgRelease ~= "E";
		}
	}
	alias DE = ManagedUnion!(D, E);
	{
		DE o;
		o.initialize!0(msgRelease);
		assert(msgDtor == []);
		assert(msgRelease == []);
		o.initialize!E( (() @trusted => &msgRelease )() );
		assert(msgDtor == ["D"]);
		assert(msgRelease == ["D"]);
	}
	assert(msgDtor == ["D", "E"]);
	assert(msgRelease == ["D", "E"]);
	
}




// 
private struct AttrData(T) {}

/*******************************************************************************
 * 
 */
alias data = AttrData;


/*******************************************************************************
 * 
 */
template hasData(alias value)
{
	static if (hasIgnore!value)
	{
		enum bool hasData = false;
	}
	else static if (hasUDA!(value, data))
	{
		enum bool hasData = true;
	}
	else
	{
		enum bool hasData = false;
	}
}

/*******************************************************************************
 * 
 */
template getDatas(alias value)
if (hasData!value)
{
	alias getDatas = staticMap!(TemplateArgsOf, getUDAs!(value, AttrData));
}

private template DataType(alias e)
if (hasData!e)
{
	import std.typecons;
	static if (getDatas!e.length == 1)
	{
		alias DataType = getDatas!e[0];
	}
	else
	{
		alias DataType = Tuple!(getDatas!e);
	}
}

/*******************************************************************************
 * 
 */
template Data(alias e)
if (hasData!e)
{
	@e enum Data: DataType!e;
}


/*******************************************************************************
 * 
 */
mixin template EnumMemberAlieses(T)
if (is(T == enum))
{
	mixin((){
		string ret;
		static foreach (e; __traits(allMembers, T))
			ret ~= "alias " ~ e ~ " = T." ~ e ~ ";";
		return ret;
	}());
}





private template matchFuncInfo(MU, alias F)
if (isInstanceOf!(ManagedUnion, MU))
{
	alias IndexType   = MU.IndexType;
	alias TagType     = MU.TagType;
	alias notfoundTag = MU.notfoundTag;
	
	static if (isCallable!F)
	{
		alias params = Parameters!F;
		enum bool isDefault  = params.length == 0;
		static if (!isDefault)
		{
			enum bool isCatch    = params.length == 1 && is(params[0]: Exception);
			enum bool isCallback = params.length == 1 && MU._implT.hasType!(params[0]);
			static if (isCallback)
			{
				enum TagType   tag   = MU._impl.getTag!(MU._implT.getTypeIndex!(params[0]));
				enum IndexType index = MU._implT.getTypeIndex!(params[0]);
			}
			else
			{
				enum TagType   tag   = notfoundTag;
				enum IndexType index = notfoundTag;
			}
		}
		else
		{
			enum bool isCatch    = false;
			enum bool isCallback = false;
			enum TagType   tag   = notfoundTag;
			enum IndexType index = notfoundTag;
		}
		alias RetType = ReturnType!F;
	}
	else
	{
		alias params = AliasSeq!(void);
		enum bool isDefault  = true;
		enum bool isCatch    = false;
		enum bool isCallback = false;
		alias RetType = typeof(F);
	}
	enum bool isMatchFunction = isDefault || isCatch || isCallback;
}

@safe unittest
{
	alias U = ManagedUnion!(int, short, long);
	
	static assert(!matchFuncInfo!(U, (int x) => x + 1).isDefault);
	static assert(!matchFuncInfo!(U, (Exception x) => 1).isDefault);
	static assert( matchFuncInfo!(U, () => 1).isDefault);
	static assert( matchFuncInfo!(U, 1).isDefault);
	
	static assert( matchFuncInfo!(U, (int x) => x + 1).isCallback);
	static assert(!matchFuncInfo!(U, () => 1).isCallback);
	static assert(!matchFuncInfo!(U, (Exception x) => 1).isCallback);
	static assert(!matchFuncInfo!(U, 1).isCallback);
	
	static assert(!matchFuncInfo!(U, (int x) => x + 1).isCatch);
	static assert( matchFuncInfo!(U, (Exception x) => 1).isCatch);
	static assert(!matchFuncInfo!(U, () => 1).isCatch);
	static assert(!matchFuncInfo!(U, 1).isCatch);
	
	static assert(is(matchFuncInfo!(U, (int x) => x + 1).RetType == int));
	static assert(is(matchFuncInfo!(U, (Exception x) => 1).RetType == int));
	static assert(is(matchFuncInfo!(U, () => 1).RetType == int));
	static assert(is(matchFuncInfo!(U, 1).RetType == int));
}

private template matchFuncInfo(ED, alias F)
if (isInstanceOf!(Endata, ED))
{
	alias IndexType   = ED._impl.IndexType;
	alias TagType     = ED._impl.TagType;
	alias notfoundTag = ED._impl.notfoundTag;
	
	static if (isCallable!F)
	{
		alias params = Parameters!F;
		enum bool isDefault  = params.length == 0;
		static if (!isDefault)
		{
			enum bool isCatch    = params.length == 1 && is(params[0]: Exception);
			enum bool isCallback = params.length == 1 && isInstanceOf!(Data, params[0]);
			static if (isCallback)
			{
				enum TagType   tag   = getUDAs!(params[0], TagType)[0];
				enum IndexType index = ED._impl.getIndex!tag;
			}
			else
			{
				enum TagType   tag   = notfoundTag;
				enum IndexType index = ED._impl.getIndex!tag;
			}
		}
		else
		{
			enum bool isCatch    = false;
			enum bool isCallback = false;
			enum TagType   tag   = notfoundTag;
			enum IndexType index = ED._impl.getIndex!tag;
		}
		alias RetType = ReturnType!F;
	}
	else
	{
		alias params = AliasSeq!();
		enum bool isDefault  = true;
		enum bool isCatch    = false;
		enum bool isCallback = false;
		alias RetType = typeof(F);
	}
	enum bool isMatchFunction = isDefault || isCatch || isCallback;
}


@safe unittest
{
	enum E { @data!int a, @data!string b }
	mixin EnumMemberAlieses!E;
	alias U = Endata!E;
	
	static assert(!matchFuncInfo!(U, (Data!a x) => x + 1).isDefault);
	static assert(!matchFuncInfo!(U, (Exception x) => 1).isDefault);
	static assert( matchFuncInfo!(U, () => 1).isDefault);
	static assert( matchFuncInfo!(U, 1).isDefault);
	
	static assert( matchFuncInfo!(U, (Data!a x) => x + 1).isCallback);
	static assert(!matchFuncInfo!(U, () => 1).isCallback);
	static assert(!matchFuncInfo!(U, (Exception x) => 1).isCallback);
	static assert(!matchFuncInfo!(U, 1).isCallback);
	
	static assert(!matchFuncInfo!(U, (Data!a x) => x + 1).isCatch);
	static assert( matchFuncInfo!(U, (Exception x) => 1).isCatch);
	static assert(!matchFuncInfo!(U, () => 1).isCatch);
	static assert(!matchFuncInfo!(U, 1).isCatch);
	
	static assert(is(matchFuncInfo!(U, (Data!a x) => x + 1).RetType == int));
	static assert(is(matchFuncInfo!(U, (Exception x) => 1).RetType == int));
	static assert(is(matchFuncInfo!(U, () => 1).RetType == int));
	static assert(is(matchFuncInfo!(U, 1).RetType == int));
}

private template matchInfo(MU, Funcs...)
if (isInstanceOf!(ManagedUnion, MU) || isInstanceOf!(Endata, MU))
{
	alias IndexType   = MU.IndexType;
	alias TagType     = MU.TagType;
	alias notfoundTag = MU.notfoundTag;
	
	enum bool isDefault(alias F)     = matchFuncInfo!(MU, F).isDefault;
	enum bool isCatch(alias F)       = matchFuncInfo!(MU, F).isCatch;
	enum bool isCallback(alias F)    = matchFuncInfo!(MU, F).isCallback;
	enum bool isMatchFunc(alias F)   = matchFuncInfo!(MU, F).isMatchFunction;
	enum TagType getTag(alias F)     = matchFuncInfo!(MU, F).tag;
	enum IndexType getIndex(alias F) = matchFuncInfo!(MU, F).index;
	alias getParams(alias F)         = matchFuncInfo!(MU, F).params;
	alias getRetType(alias F)        = matchFuncInfo!(MU, F).RetType;
	
	alias RetType          = CommonType!(staticMap!(getRetType, Funcs));
	enum bool canMatch     = allSatisfy!(isMatchFunc, Funcs) && !is(returnType == void);
	enum size_t defaultIdx = staticIndexOf!(true, staticMap!(isDefault, Funcs));
	enum bool hasDefault   = defaultIdx != -1;
	alias callbacks        = Filter!(isCallback, Funcs);
	alias catches          = Filter!(isCatch, Funcs);
	enum bool hasCatch     = catches.length;
	
	// コールバックはメンバの数以下しかかけない
	static assert(callbacks.length <= MU._impl.memberCount);
	// コールバックがメンバ全部に対応して書かれている場合はデフォルト不要
	static if (callbacks.length == MU._impl.memberCount)
		static assert(!hasDefault);
	// コールバックがメンバ全部に対応して書かれていない場合はデフォルトが必須
	static if (callbacks.length < MU._impl.memberCount)
		static assert(hasDefault);
	// デフォルト関数は1追加
	static assert(Filter!(isDefault, Funcs).length <= 1);
}


@safe pure nothrow unittest
{
	import std.exception;
	import std.conv: ConvException;
	alias U = ManagedUnion!(int, short, long);
	U dat;
	static assert(U._inst.sizeof == long.sizeof);
	static assert(!U.hasType!char);
	static assert(U.sizeof == long.sizeof + size_t.sizeof);
	static assert(U.hasType!short);
	static assert(U.getTypeIndex!short == 1);
	static assert(U.getAssignableIndex!short == 1);
	static assert(U.getAssignableIndex!long  == 2);
	static assert(U.isAssignable!byte);
	static assert(U.getAssignableIndex!byte  == 0);
	static assert(!U.hasType!char);
	
	
	dat = 1;
	
	alias MatchInfo1 = matchInfo!(U,
		(int x) => x + 1,
		(short x) => x + 50,
		(long x) => x + 100);
	static assert(MatchInfo1.canMatch);
	static assert(is(MatchInfo1.RetType == long));
	
	alias MatchInfo2 = matchInfo!(U,
		(int x) => x + 1,
		() => 50,
		(long x) => x + 100);
	static assert(MatchInfo2.canMatch);
	static assert(MatchInfo2.defaultIdx == 1);
	static assert(MatchInfo2.callbacks.length == 2);
	static assert(is(MatchInfo2.RetType == long));
	
	alias MatchInfo3 = matchInfo!(U,
		(long x) => x + 100*1.0f,
		(Exception e) => 1*1.0,
		() => 50*1.0);
	static assert(MatchInfo3.canMatch);
	static assert(MatchInfo3.defaultIdx == 2);
	static assert(MatchInfo3.catches.length == 1);
	static assert(MatchInfo3.callbacks.length == 1);
	static assert(is(MatchInfo3.RetType == double));
	
	alias MatchInfo4 = matchInfo!(U,
		(Exception e) => 100,
		()            => 50,
		(long x)      => enforce(0));
	static assert(MatchInfo4.canMatch);
	static assert(MatchInfo4.hasDefault);
	static assert(MatchInfo4.hasCatch);
	static assert(MatchInfo4.defaultIdx == 1);
}


/*******************************************************************************
 * パターンマッチ
 */
template match(Funcs...)
{
	template match(MU)
	if (matchInfo!(MU, Funcs).canMatch)
	{
		alias minfo = matchInfo!(MU, Funcs);
		
		// 関数本体
		pragma(inline) auto ref matchImpl(inout ref MU dat)
		{
			static if (minfo.hasDefault)
			{
				switch (dat._impl._tag)
				{
				static foreach (F; minfo.callbacks) case minfo.getTag!F:
					return F(cast(inout minfo.getParams!F[0])dat._impl._inst.tupleof[minfo.getIndex!F]);
				default:
					static if (isCallable!(Funcs[minfo.defaultIdx]))
						return Funcs[minfo.defaultIdx]();
					else
						return Funcs[minfo.defaultIdx];
				}
			}
			else
			{
				final switch (dat._impl._tag)
				{
				static foreach (F; minfo.callbacks) case minfo.getTag!F:
					return F(dat._impl._inst.tupleof[minfo.getIndex!F]);
				}
			}
		}
		
		// 関数本体
		pragma(inline) auto ref match(inout ref MU dat)
		{
			static if (minfo.hasCatch)
			{
				// 例外処理が必要な場合
				mixin((){
					string code = ` try { return matchImpl(dat); }`;
					static foreach (i, F; minfo.catches)
						static if (minfo.isCatch!F)
							code ~= ` catch (minfo.getParams!(minfo.catches[`~i.stringof~`])[0] e)`
							     ~  ` { return minfo.catches[`~ i.stringof ~`](e); } `;
					else
						code ~= `assert(0);`;
					return code;
				}());
			}
			else
			{
				// 例外処理が不要な場合
				return matchImpl(dat);
			}
		}
	}
}

@safe pure @nogc nothrow unittest
{
	import std.exception;
	import std.conv: ConvException;
	import voile.misc: nogcEnforce;
	alias U = ManagedUnion!(int, short, long);
	U dat;
	dat.set!0 = 1;
	
	assert(dat.match!(
		(int x)  => x + 1,
		()       => 50,
		(long x) => x + 100) == 2);
	
	dat = cast(long)100;
	assert(dat.match!(
		(int x)  => x + 1,
		()       => 50,
		(long x) => x + 100) == 200);
	
	assert(!dat.empty);
	dat.clear();
	assert(dat.empty);
	
	assert(dat.match!(
		(int x)  => x + 1,
		()       => 50,
		(long x) => x + 100) == 50);
	
	dat = U(cast(long)0);
	assert(dat.match!(
		(Exception e) => 100,
		()            => 50,
		(long x)      => nogcEnforce(0)) == 100);
	
	dat = cast(long)10;
	try dat.match!(
		(ConvException e) => 100,
		()            => 50,
		(long x)      => nogcEnforce(0));
	catch (Exception)
		dat = 5;
	assert(dat.get!int == 5);
}