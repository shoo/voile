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

private mixin template ManagedUnionImpl(Instance, tags...)
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
		import std.range: iota;
		alias allTags = aliasSeqOf!(iota(0, MemberTypes.length));
	}
	else
	{
		enum TagType getTag(IndexType idx) = tags[idx];
		enum IndexType getIndex(TagType t) = cast(IndexType)staticIndexOf!(t, tags);
		alias allTags = tags;
	}
	
	enum TagType notfoundTag = cast(TagType)(-1);
	
	struct
	{
		TagType  _tag = notfoundTag;
		Instance _inst;
	}
	
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
	void initialize(TagType t, Args...)(auto ref Args args) @trusted
	if (getIndex!t != cast(IndexType)notfoundTag && getIndex!t < memberCount)
	{
		static if (hasDestructor)
			clear();
		_emplace(_inst.tupleof[getIndex!t], args);
		_tag = t;
	}
	/// ditto
	void initialize(TagType t)() @trusted
	if (getIndex!t == cast(IndexType)notfoundTag)
	{
		static if (hasDestructor)
			clear();
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
	auto ref get(TagType t)() nothrow pure @nogc inout @trusted @property
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
	void clear()() @trusted
	{
		scope (exit)
			_tag = notfoundTag;
		static if (hasDestructor)
		{
			switch (_tag)
			{
				static foreach (i, T; MemberTypes)
				{
				case getTag!i:
					static if (hasElaborateDestructor!T)
						_inst.tupleof[i]._move();
					return;
				}
				default:
					return;
			}
		}
	}
}

/*******************************************************************************
 * 型列挙
 */
private union TypeEnumImpl(Types...)
{
	alias FieldTypes = Types;

	union Instance
	{
		mixin template DefineMember(T)
		{
			T _value;
		}
		static foreach (T; FieldTypes)
			mixin DefineMember!T;
	}
	mixin ManagedUnionImpl!Instance _impl;
	
	template WithType()
	{
		template TargetTypeInfo(T)
		{
			enum IndexType typeIndex = cast(IndexType)staticIndexOf!(T, MemberTypes);
			enum bool hasType        = typeIndex != _impl.notfoundTag;
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
		void initialize(T, Args...)(auto ref Args args) @trusted
		if (hasType!T)
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
		if (isAssignable!T)
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
		auto ref get(T)() nothrow pure @nogc inout @trusted @property
		if (hasType!T)
		in (getTag!(getAssignableIndex!T) == _tag)
		{
			enum idx = getAssignableIndex!T;
			return _inst.tupleof[idx];
		}
		
		/***********************************************************************
		 * データがセットされているかチェックする
		 */
		bool check(T)() nothrow pure @nogc @safe const
		if (hasType!T)
		{
			return _tag == getTag!(getTypeIndex!T);
		}
	}
	mixin WithType _implT;
}


/*******************************************************************************
 * 型列挙
 */
struct TypeEnum(Types...)
if (Types.length > 0 && NoDuplicates!Types.length == Types.length)
{
	private TypeEnumImpl!Types _inst;
	/***************************************************************************
	 * コンストラクタ
	 */
	this(T)(auto ref T val) @trusted
	if (_inst.isAssignable!T)
	{
		enum idx = _inst.getAssignableIndex!T;
		static if (__traits(isRef, val))
			_inst._impl._inst.tupleof[idx] = val;
		else
			_inst._impl._inst.tupleof[idx] = val._move();
		_inst._impl._tag = idx;
	}
	
	
	static if (TypeEnumImpl!Types._impl.hasDestructor)
	{
		// 型のうちいずれかがデストラクタを持つ場合、対処する
		public ~this()
		{
			_inst._impl.clear();
		}
	}
	
	/***************************************************************************
	 * 代入
	 */
	void opAssign(T)(auto ref T val)
	if (_inst.isAssignable!T)
	{
		static if (_inst.hasDestructor)
			_inst.clear();
		enum idx = _inst.getAssignableIndex!T;
		_inst.initialize!idx(val);
		static if (is(T == struct) && hasElaborateDestructor!T && !__traits(isRef, val))
			_initialize(val);
	}
	
	/***************************************************************************
	 * キャスト
	 */
	inout(T) opCast(T)() inout
	if (_inst.isAssignable!T)
	{
		return _inst._implT.get!T();
	}
	
	/***************************************************************************
	 * 等号演算子オーバーロード
	 */
	bool opEquals()(TypeEnum rhs) const
	{
		final switch (_inst._impl._tag)
		{
			static foreach (i; 0.._inst._impl.MemberTypes.length)
			{
			case _inst._impl.getTag!i:
				return _inst._impl.getTag!i == rhs._inst._impl._tag
				    && _inst._impl._inst.tupleof[i] == rhs._inst._impl._inst.tupleof[i];
			}
		}
	}
	
	/***************************************************************************
	 * ハッシュ
	 */
	size_t toHash()() const
	{
		size_t hash;
		hashOf(_inst._impl._tag, hash);
		switch (_inst._impl._tag)
		{
			static foreach (i; 0.._inst._impl.MemberTypes.length)
			{
			case _inst._impl.getTag!i:
				hashOf(_inst._impl._inst.tupleof[i], hash);
			}
			default:
				break;
		}
		return hash;
	}
}

///
@safe pure nothrow @nogc unittest
{
	alias U = TypeEnum!(int, string);
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
	set!int(dat, 5);
	assert(dat.get!int == 5);
//	dat.set!1 = "foo";
//	assert(dat.get!1 == "foo");
	
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
	alias U = TypeEnum!(int, short, long);
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
 * タグ付き共用体
 */
private union TaggedImpl(U)
{
	alias FieldTypes = Fields!U;
	alias Instance = U;
	mixin ManagedUnionImpl!Instance _impl;
	alias memberNames = FieldNameTuple!Instance;
	enum _impl.IndexType getIndex(string member) = cast(_impl.IndexType)staticIndexOf!(member, memberNames);
	enum _impl.TagType   getTag(string member)   = _impl.getTag!(getIndex!member);
	alias MemberType(string member)              = _impl.MemberTypes[getIndex!member];
}


/*******************************************************************************
 * タグ付き共用体
 */
struct Tagged(U)
if (is(U == union))
{
	mixin(`private TaggedImpl!U ` ~ uniqueMemberName!U ~ `;`);
	
	static if (TaggedImpl!U._impl.hasDestructor)
	{
		// 型のうちいずれかがデストラクタを持つ場合、対処する
		public ~this()
		{
			final switch (__traits(getMember, this, uniqueMemberName!U)._impl._tag)
			{
				static foreach (i, T; TaggedImpl!U._impl.MemberTypes)
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
	 * 等号演算子オーバーロード
	 */
	bool opEquals()(Tagged rhs) const
	{
		final switch (__traits(getMember, this, uniqueMemberName!U)._impl._tag)
		{
			static foreach (i; 0..__traits(getMember, this, uniqueMemberName!U)._impl.MemberTypes.length)
			{
			case __traits(getMember, this, uniqueMemberName!U)._impl.getTag!i:
				return __traits(getMember, this, uniqueMemberName!U)._impl.getTag!i
				       == __traits(getMember, rhs, uniqueMemberName!U)._impl._tag
				    && __traits(getMember, this, uniqueMemberName!U)._impl._inst.tupleof[i]
				       == __traits(getMember, rhs, uniqueMemberName!U)._impl._inst.tupleof[i];
			}
		}
	}
	
	/***************************************************************************
	 * ハッシュ
	 */
	size_t toHash()() const
	{
		size_t hash;
		hashOf(__traits(getMember, this, uniqueMemberName!U)._impl._tag, hash);
		switch (__traits(getMember, this, uniqueMemberName!U)._impl._tag)
		{
			static foreach (i; 0..__traits(getMember, this, uniqueMemberName!U)._impl.MemberTypes.length)
			{
			case __traits(getMember, this, uniqueMemberName!U)._impl.getTag!i:
				hashOf(__traits(getMember, this, uniqueMemberName!U)._impl._inst.tupleof[i], hash);
			}
			default:
				break;
		}
		return hash;
	}
	
	/***************************************************************************
	 * 名前アクセス
	 * 
	 * Taggedの引数に共用体を与えた場合は名前でのアクセスを許可する。
	 * See_Also: $(D $(LINK2 _voile--_voile.munion.html#.Managed, Managed))
	 */
	auto ref opDispatch(string member)()
	if (hasMember!(TaggedImpl!U.Instance, member))
	{
		return __traits(getMember, this, uniqueMemberName!U).get!(TaggedImpl!U.getTag!member);
	}
	/// ditto
	void opDispatch(string member)(auto ref TaggedImpl!U.MemberType!member val)
	if (hasMember!(TaggedImpl!U.Instance, member))
	{
		__traits(getMember, this, uniqueMemberName!U).set!(TaggedImpl!U.getTag!member)(val);
	}
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
	
	alias MU = Tagged!U;
	
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
 * Taggedの構築
 */
Tagged!U tagged(U, size_t memberIndex, Args...)(auto ref Args args)
{
	alias TU = Tagged!U;
	enum tag = TaggedImpl!TU._impl.getTag!memberIndex;
	TU dat;
	dat.initialize!tag(args);
	return dat;
}
/// ditto
Tagged!U tagged(U, string memberName, Args...)(auto ref Args args)
{
	alias TU = Tagged!U;
	enum tag = TaggedImpl!U.getTag!memberName;
	TU dat;
	dat.getInstance()._impl.initialize!tag(args);
	return dat;
}
///
@safe pure nothrow @nogc unittest
{
	union U
	{
		uint   x;
		uint   y;
	}
	
	auto dat = tagged!(U, 0)(10);
	assert(dat.tag == 0);
	assert(dat.x == 10);
	
	dat = tagged!(U, "y")(20);
	assert(dat.tag == 1);
	assert(dat.y == 20);
}

private union EndataImpl(E)
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
	mixin ManagedUnionImpl!(Instance, tags) _impl;
	alias memberNames = FieldNameTuple!Instance;
	enum _impl.IndexType getIndex(string member) = cast(_impl.IndexType)staticIndexOf!(member, memberNames);
	enum _impl.TagType   getTag(string member)   = _impl.getTag!(getIndex!member);
	alias MemberType(string member)              = _impl.MemberTypes[getIndex!member];
}


/*******************************************************************************
 * データ付きのenum
 */
struct Endata(E)
if (is(E == enum))
{
	mixin(`private EndataImpl!E ` ~ uniqueMemberName!E ~ `;`);
	
	/***************************************************************************
	 * 等号演算子オーバーロード
	 */
	bool opEquals()(Endata rhs) const
	{
		switch (__traits(getMember, this, uniqueMemberName!E)._impl._tag)
		{
			static foreach (e; EnumMembers!(EndataImpl!E.TagType))
			{
			case e:
				static if (EndataImpl!E._impl.getIndex!e != cast(EndataImpl!E._impl.IndexType)EndataImpl!E._impl.notfoundTag)
				{
					return e == __traits(getMember, rhs, uniqueMemberName!E)._impl._tag
					    && __traits(getMember, this, uniqueMemberName!E)._impl._inst.tupleof[EndataImpl!E._impl.getIndex!e]
					        == __traits(getMember, rhs, uniqueMemberName!E)._impl._inst.tupleof[EndataImpl!E._impl.getIndex!e];
				}
				else
				{
					return e == __traits(getMember, rhs, uniqueMemberName!E)._impl._tag;
				}
			}
			default:
				return false;
		}
	}
	
	/***************************************************************************
	 * ハッシュ
	 */
	size_t toHash()() const
	{
		size_t hash;
		hashOf(__traits(getMember, this, uniqueMemberName!E)._impl._tag, hash);
		switch (__traits(getMember, this, uniqueMemberName!E)._impl._tag)
		{
			static foreach (i; 0..__traits(getMember, this, uniqueMemberName!E)._impl.MemberTypes.length)
			{
			case __traits(getMember, this, uniqueMemberName!E)._impl.getTag!i:
				hashOf(__traits(getMember, this, uniqueMemberName!E)._impl._inst.tupleof[i], hash);
			}
			default:
				break;
		}
		return hash;
	}
	
	/***************************************************************************
	 * 名前アクセス
	 */
	auto ref opDispatch(string member)()
	if (hasMember!(EndataImpl!E.Instance, member))
	{
		return __traits(getMember, this, uniqueMemberName!E)._impl.get!(EndataImpl!E.getTag!member);
	}
	/// ditto
	void opDispatch(string member)(auto ref EndataImpl!E.MemberType!member val)
	if (hasMember!(EndataImpl!E.Instance, member))
	{
		__traits(getMember, this, uniqueMemberName!E)._impl.set!(EndataImpl!E.getTag!member)(val);
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
	static assert(!__traits(compiles, dat.set!ignored(0)));
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
	
	static assert(typeof(dat.getInstance()).getTag!"number" == number);
	static assert(is(typeof(dat.getInstance()).MemberType!"number" == int));
	
	dat.number = 10;
	assert(dat.tag == number);
	assert(dat.number == 10);
}

/*******************************************************************************
 * Endataの構築
 */
Endata!(typeof(tag)) endata(alias tag, Args...)(auto ref Args payload)
{
	Endata!(typeof(tag)) dat;
	dat.initialize!tag(payload);
	return dat;
}

///
@safe pure nothrow @nogc unittest
{
	enum E
	{
		@data!int id,
		@data!int number,
	}
	mixin EnumMemberAlieses!E;
	
	auto dat = endata!id(10);
	assert(dat.tag == id);
	assert(dat.id == 10);
}

/*******************************************************************************
 * 引数によって実装を切り替えるManagedUnion
 * 
 * - 引数が1つでunionならTaggedになる
 * - 引数が1つでenumならEndataになる
 * - それ以外ならTypeEnumになる
 */
template ManagedUnion(Types...)
if (Types.length > 0)
{
	static if (Types.length == 1 && is(Types[0] == union))
	{
		alias ManagedUnion = Tagged!Types;
	}
	else static if (Types.length == 1 && is(Types[0] == enum))
	{
		alias ManagedUnion = Endata!Types;
	}
	else
	{
		alias ManagedUnion = TypeEnum!Types;
	}
}



/*******************************************************************************
 * TypeEnumか判定する
 */
enum bool isTypeEnum(MU) = isInstanceOf!(TypeEnum, MU);

/*******************************************************************************
 * Taggedか判定する
 */
enum bool isTagged(MU) = isInstanceOf!(Tagged, MU);

/*******************************************************************************
 * Endataか判定する
 */
enum bool isEndata(MU) = isInstanceOf!(Endata, MU);

/*******************************************************************************
 * ManagedUnionか判定する
 */
enum bool isManagedUnion(MU) = isTypeEnum!MU || isTagged!MU || isEndata!MU;





private pragma(inline) ref getInstance(MU)(ref MU dat) pure nothrow @nogc @safe
{
	static if (isTypeEnum!MU)
	{
		return dat._inst;
	}
	else
	{
		alias A = TemplateArgsOf!MU;
		return __traits(getMember, dat, uniqueMemberName!A);
	}
}
private template ImplOf(MU)
{
	alias A = TemplateArgsOf!MU;
	static if (isTypeEnum!MU)
	{
		alias ImplOf = TypeEnumImpl!A._impl;
	}
	else static if (isTagged!MU)
	{
		alias ImplOf = TaggedImpl!A._impl;
	}
	else static if (isEndata!MU)
	{
		alias ImplOf = EndataImpl!A._impl;
	}
	else static assert(0);
}

private alias TypeImplOf(MU) = TypeEnumImpl!(TemplateArgsOf!MU)._implT;

/*******************************************************************************
 * ManagedUnionのタグ型を得る
 */
template TagType(MU)
if (isManagedUnion!MU)
{
	alias TagType = ImplOf!MU.TagType;
}
///
@safe @nogc nothrow pure unittest
{
	static assert(is(TagType!(TypeEnum!(int, string)) == ubyte));
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	static assert(is(TagType!(Endata!E) == E));
}

/*******************************************************************************
 * 有効なタグか確認する
 */
template isAvailableTag(MU, alias tag)
if (isManagedUnion!MU)
{
	static if (!isType!tag && isOrderingComparable!(CommonType!(typeof(tag), TagType!MU)))
	{
		enum bool isAvailableTag = ImplOf!MU.getIndex!tag < ImplOf!MU.memberCount;
	}
	else
	{
		enum bool isAvailableTag = false;
	}
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	static assert( isAvailableTag!(MU, 1));
	static assert(!isAvailableTag!(MU, 2));
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	static assert(isAvailableTag!(Endata!E, E.x));
	static assert(isAvailableTag!(Endata!E, E.str));
	static assert(!isAvailableTag!(Endata!E, getNotFoundTag!(Endata!E)));
	static assert(!isAvailableTag!(Endata!E, cast(E)3));
}

/*******************************************************************************
 * 無効なタグを取得する
 */
template getNotFoundTag(MU)
if (isManagedUnion!MU)
{
	enum ImplOf!MU.TagType getNotFoundTag = ImplOf!MU.notfoundTag;
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	static assert(getNotFoundTag!MU != 0);
	static assert(getNotFoundTag!MU != 1);
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	alias MU = Endata!E;
	static assert(getNotFoundTag!MU != E.x);
	static assert(getNotFoundTag!MU != E.str);
}

/*******************************************************************************
 * 型を持っているか確認する
 */
template hasType(MU, T)
if (isTypeEnum!MU)
{
	enum bool hasType = TypeImplOf!MU.hasType!T;
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	static assert(hasType!(MU, int));
	static assert(hasType!(MU, string));
	static assert(!hasType!(MU, long));
}



/*******************************************************************************
 * 持っている型を列挙する
 */
template EnumMemberTypes(MU)
if (isManagedUnion!MU)
{
	alias EnumMemberTypes = ImplOf!MU.MemberTypes;
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	alias Types = EnumMemberTypes!MU;
	static assert(is(Types[0] == int));
	static assert(is(Types[1] == string));
}


/*******************************************************************************
 * タグを列挙する
 */
template memberTags(MU)
if (isManagedUnion!MU)
{
	enum ImplOf!MU.TagType[] memberTags = (){
		ImplOf!MU.TagType[] ret;
		static foreach (i; 0..ImplOf!MU.MemberTypes.length)
			ret ~= ImplOf!MU.getTag!i;
		return ret;
	}();
}

/// ditto
enum allTags(MU) = EnumMembers!(ImplOf!MU.TagType);

/// ditto
template EnumMemberTags(MU)
if (isManagedUnion!MU)
{
	alias EnumMemberTags = aliasSeqOf!(memberTags!MU);
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	enum tags = memberTags!MU;
	static assert(tags.length == 2);
	static assert(tags[0] == 0);
	static assert(tags[1] == 1);
	
	alias MemberTags = EnumMemberTags!MU;
	static assert(MemberTags.length == 2);
	static assert(MemberTags[0] == 0);
	static assert(MemberTags[1] == 1);
}


/*******************************************************************************
 * タグから型を得る
 */
template TypeFromTag(MU, alias tag)
if (isManagedUnion!MU)
{
	alias TypeFromTag = ImplOf!MU.MemberTypes[ImplOf!MU.getIndex!tag];
}
///
@safe @nogc nothrow pure unittest
{
	alias MU1 = TypeEnum!(int, string);
	static assert(is(TypeFromTag!(MU1, 0) == int));
}


/*******************************************************************************
 * 型が代入可能か
 */
template isTypeAssignable(MU, T)
if (isTypeEnum!MU)
{
	enum bool isTypeAssignable = TypeImplOf!MU.isAssignable!T;
}

/*******************************************************************************
 * タグを確認する
 */
TagType!MU tag(MU)(auto const ref MU dat)
if (isManagedUnion!MU)
{
	return dat.getInstance()._tag;
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	MU tu;
	assert(tag(tu) == getNotFoundTag!MU);
	tu = 1;
	assert(tag(tu) != getNotFoundTag!MU);
	assert(tag(tu) == 0);
	tu = "1";
	assert(tag(tu) != getNotFoundTag!MU);
	assert(tag(tu) == 1);
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	assert(tag(dat) == getNotFoundTag!ED);
	dat.x = 1;
	assert(tag(dat) != getNotFoundTag!ED);
	assert(tag(dat) == x);
	dat.str = "1";
	assert(tag(dat) != getNotFoundTag!ED);
	assert(tag(dat) == str);
}

/*******************************************************************************
 * 初期化する
 */
void initialize(alias tag, MU, Args...)(auto ref MU dat, auto ref Args args)
if (isManagedUnion!MU && isAvailableTag!(MU, tag))
{
	dat.getInstance()._impl.initialize!tag(args);
}
/// ditto
void initialize(T, MU, Args...)(auto ref MU dat, auto ref Args args)
if (isTypeEnum!MU && hasType!(MU, T))
{
	dat.getInstance()._implT.initialize!T(args);
}
/// ditto
void initialize(alias tag, MU)(auto ref MU dat)
if (isEndata!MU && !isAvailableTag!(MU, tag)
 && ImplOf!MU.getIndex!tag == cast(ImplOf!MU.IndexType)ImplOf!MU.notfoundTag)
{
	dat.getInstance()._impl.initialize!tag();
}
///
@safe @nogc nothrow pure unittest
{
	struct S { int x; }
	alias MU = TypeEnum!(int, S);
	MU dat;
	initialize!0(dat, 1);
	assert(get!0(dat) == 1);
	initialize!1(dat, 100);
	assert(get!1(dat) == S(100));
	// for type
	initialize!int(dat, 1000);
	assert(get!0(dat) == 1000);
}
///
@safe unittest
{
	import std.datetime: Date;
	enum E { @data!int x, @data!Date date, test }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	initialize!x(dat, 1);
	assert(get!x(dat) == 1);
	initialize!date(dat, Date(2020, 8, 5));
	assert(get!date(dat) == Date(2020, 8, 5));
	initialize!test(dat);
	assert(tag(dat) == test);
}


/*******************************************************************************
 * データをセットする
 */
void set(alias tag, MU, T)(ref auto MU dat, auto ref T val) @property
if (isManagedUnion!MU && isAvailableTag!(MU, tag))
{
	dat.getInstance()._impl.set!tag(val);
	static if (hasElaborateDestructor!T && !__traits(isRef, val))
		_initialize(val);
}
/// ditto
void set(T, MU)(ref MU dat, auto ref T val) @property
if (isTypeEnum!MU && hasType!(MU, T))
{
	dat.getInstance()._implT.set!T(val);
	static if (hasElaborateDestructor!T && !__traits(isRef, val))
		_initialize(val);
}
///
@safe @nogc nothrow pure unittest
{
	struct S { int x; }
	alias MU = TypeEnum!(int, S);
	MU dat;
	dat.set!0 = 1;
	assert(get!0(dat) == 1);
	set!1(dat, S(100));
	assert(get!1(dat) == S(100));
	// for type
	dat.set!int = 10;
	assert(dat.get!0 == 10);
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	dat.set!x = 1;
	assert(dat.tag == x);
	set!str(dat, "test");
	assert(dat.tag == str);
}

/*******************************************************************************
 * データを取得する
 */
auto ref get(alias tag, MU)(inout auto ref MU dat)
if (isManagedUnion!MU && isAvailableTag!(MU, tag))
{
	return dat.getInstance()._impl.get!tag();
}
/// ditto
auto ref get(T, MU)(inout auto ref MU dat)
if (isTypeEnum!MU && hasType!(MU, T))
{
	return dat.getInstance()._implT.get!T();
}
///
@safe unittest
{
	import core.exception: AssertError;
	import std.exception;
	alias MU = TypeEnum!(int, string);
	MU tu;
	(() @trusted => assertThrown!AssertError(get!0(tu) == 1) )();
	set!1(tu, "test");
	assert(get!1(tu) == "test");
	// for type
	assert(get!string(tu) == "test");
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	dat.set!x = 1;
	assert(.get!x(dat) == 1);
	dat.set!str = "test";
	assert(dat.get!str == "test");
	assert(dat.check!str);
}

/*******************************************************************************
 * データが入っていることを確認する
 */
bool check(alias tag, MU)(auto const ref MU dat)
if (isManagedUnion!MU && isAvailableTag!(MU, tag))
{
	return dat.getInstance()._impl.check!tag();
}
/// ditto
bool check(T, MU)(auto const ref MU dat)
if (isTypeEnum!MU && hasType!(MU, T))
{
	return dat.getInstance()._implT.check!T();
}
///
@safe unittest
{
	alias MU = TypeEnum!(int, string);
	MU tu;
	assert(!tu.check!0);
	assert(!tu.check!1);
	tu.set!1 = "test";
	assert(!tu.check!0);
	assert(tu.check!1);
	// for type
	assert(tu.check!string);
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	dat.set!x = 1;
	assert(dat.check!x);
	dat.set!str = "test";
	assert(dat.check!str);
}

/*******************************************************************************
 * データをクリアする
 */
void clear(MU)(auto ref MU dat)
if (isManagedUnion!MU)
{
	dat.getInstance()._impl.clear();
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	MU tu;
	assert(!tu.check!0);
	assert(!tu.check!1);
	tu.set!1 = "test";
	assert(!tu.check!0);
	assert(tu.check!1);
	tu.clear();
	assert(!tu.check!0);
	assert(!tu.check!1);
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	dat.set!x = 1;
	assert(check!x(dat));
	dat.set!str = "test";
	assert(check!str(dat));
}

/*******************************************************************************
 * データがクリアされているか確認する
 */
bool empty(MU)(auto const ref MU dat)
if (isManagedUnion!MU)
{
	return dat.getInstance()._impl.empty();
}
///
@safe @nogc nothrow pure unittest
{
	alias MU = TypeEnum!(int, string);
	MU tu;
	assert(tu.empty);
	tu.set!1 = "test";
	assert(!tu.empty);
}
///
@safe @nogc nothrow pure unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	alias ED = Endata!E;
	ED dat;
	
	assert(dat.empty);
	dat.set!x = 1;
	assert(!dat.empty);
	dat.set!str = "test";
	assert(dat.check!str);
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
	alias AB = TypeEnum!(A, B);
	
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
	alias AC = TypeEnum!(A, C);
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
	alias DE = TypeEnum!(D, E);
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
	@e union Data
	{
		template Value ()
		{
			DataType!e _instance_of_value_;
		}
		mixin Value _inst;
		alias _instance_of_value_ this;
	}
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



private template isCallableWith(alias F, Args...)
if (__traits(isTemplate, F))
{
	enum bool isCallableWith = __traits(compiles, isCallable!(F!Args));
}

private template getTempFuncParamUDAs(alias F, size_t idx, Type, CandidateTypes...)
if (__traits(isTemplate, F))
{
	import std.typecons: Tuple;
	import voile.attr: getParameterUDAs;
	static if (CandidateTypes.length == 0)
	{
		alias getTempFuncParamUDAs = AliasSeq!();
	}
	else static if (isInstanceOf!(Tuple, CandidateTypes[0]))
	{
		static if (isCallableWith!(F, CandidateTypes[0].Types))
		{
			alias getTempFuncParamUDAs = getParameterUDAs!(F!(CandidateTypes[0].Types), idx, Type);
		}
		else
		{
			alias getTempFuncParamUDAs = getTempFuncParamUDAs!(F, idx, Type, CandidateTypes[1..$]);
		}
	}
	else
	{
		static if (isCallableWith!(F, CandidateTypes[0]))
		{
			alias getTempFuncParamUDAs = getParameterUDAs!(F!(CandidateTypes[0]), idx, Type);
		}
		else
		{
			alias getTempFuncParamUDAs = getTempFuncParamUDAs!(F, idx, Type, CandidateTypes[1..$]);
		}
	}
}

@safe unittest
{
	import std.typecons: Tuple;
	enum E { @data!int a, @data!string b }
	static assert(getTempFuncParamUDAs!((@(E.a) x) => x + 1, 0, E, AliasSeq!(int, long))[0] == E.a);
	static assert(getTempFuncParamUDAs!((@(E.b) x) => x + 1, 0, E, AliasSeq!(int, long))[0] == E.b);
	static assert(getTempFuncParamUDAs!((@(E.b) @(E.a) x) => x + 1, 0, E, AliasSeq!(int, long))[0] == E.b);
	static assert(getTempFuncParamUDAs!((@(E.b) @(E.a) x) => x + 1, 0, E, AliasSeq!(int, long))[1] == E.a);
	static assert(getTempFuncParamUDAs!((@(E.a) x, @(E.b) y) => x + 1, 0, E, AliasSeq!(Tuple!(int, int)))[0] == E.a);
	static assert(getTempFuncParamUDAs!((@(E.a) x, @(E.b) y) => x + 1, 1, E, AliasSeq!(Tuple!(int, int)))[0] == E.b);
}


private template matchFuncInfo(MU, alias F)
if (isTypeEnum!MU || isTagged!MU)
{
	alias IndexType   = ImplOf!MU.IndexType;
	alias TagType     = ImplOf!MU.TagType;
	alias notfoundTag = ImplOf!MU.notfoundTag;
	alias MemberTypes = ImplOf!MU.MemberTypes;
	
	static if (isCallable!F)
	{
		alias params = Parameters!F;
		enum bool isDefault  = params.length == 0;
		static if (!isDefault)
		{
			enum bool isCatch    = params.length == 1 && is(params[0]: Exception);
			enum bool isCallback = params.length == 1 && TypeImplOf!MU.hasType!(params[0]);
			static if (isCallback)
			{
				enum TagType   tag   = ImplOf!MU.getTag!(TypeImplOf!MU.getTypeIndex!(params[0]));
				enum IndexType index = TypeImplOf!MU.getTypeIndex!(params[0]);
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
	else static if (__traits(isTemplate, F))
	{
		// other => ...
		alias params         = AliasSeq!();
		enum TagType   tag   = notfoundTag;
		enum IndexType index = ImplOf!MU.getIndex!tag;
		enum bool isDefault  = true;
		enum bool isCatch    = false;
		enum bool isCallback = false;
		alias RetTypeWith(T) = ReturnType!(F!T);
		alias RetType = CommonType!(staticMap!(RetTypeWith, Filter!(ApplyLeft!(isCallableWith, F), MemberTypes)));
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
	alias U = TypeEnum!(int, short, long);
	
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
	
	static assert(matchFuncInfo!(U, other => 1).tag == ImplOf!U.notfoundTag);
	static assert( matchFuncInfo!(U, other => 1).isDefault);
	static assert(!matchFuncInfo!(U, other => 1).isCallback);
	static assert(!matchFuncInfo!(U, other => 1).isCatch);
	static assert(is(matchFuncInfo!(U, other => 1).RetType == int));
}

private template matchFuncInfo(ED, alias F)
if (isInstanceOf!(Endata, ED))
{
	alias IndexType   = ImplOf!ED.IndexType;
	alias TagType     = ImplOf!ED.TagType;
	alias notfoundTag = ImplOf!ED.notfoundTag;
	alias MemberTypes = ImplOf!ED.MemberTypes;
	
	static if (isCallable!F)
	{
		alias params = Parameters!F;
		enum bool isDefault  = params.length == 0;
		static if (!isDefault)
		{
			import voile.attr;
			enum bool isCatch    = params.length == 1 && is(params[0]: Exception);
			enum bool isCallback = params.length == 1 && hasParameterUDA!(F, 0, TagType);
			static if (isCallback)
			{
				static if (hasParameterUDA!(F, 0, TagType))
				{
					// (Data!tag val) => ...
					// (@tag int val) => ...
					enum TagType tag = getParameterUDAs!(F, 0, TagType)[0];
				}
				else
				{
					enum TagType tag = notfoundTag;
				}
				enum IndexType index = ImplOf!ED.getIndex!tag;
			}
			else
			{
				enum TagType   tag   = notfoundTag;
				enum IndexType index = ImplOf!ED.getIndex!tag;
			}
		}
		else
		{
			enum bool isCatch    = false;
			enum bool isCallback = false;
			enum TagType   tag   = notfoundTag;
			enum IndexType index = ImplOf!ED.getIndex!tag;
		}
		alias RetType = ReturnType!F;
	}
	else static if (__traits(isTemplate, F))
	{
		// テンプレート関数が渡された場合、まずタグの有無を確認する
		alias tags = getTempFuncParamUDAs!(F, 0, TagType, MemberTypes);
		static if (tags.length == 0)
		{
			// タグがない場合、デフォルト
			// other => ...
			alias params         = AliasSeq!();
			enum TagType   tag   = notfoundTag;
			enum IndexType index = ImplOf!ED.getIndex!tag;
			enum bool isDefault  = true;
			enum bool isCatch    = false;
			enum bool isCallback = false;
			alias RetTypeWith(T) = ReturnType!(F!T);
			alias RetType = CommonType!(staticMap!(RetTypeWith, Filter!(ApplyLeft!(isCallableWith, F), MemberTypes)));
		}
		else
		{
			// タグがある場合、タグに対応した型を使用して実体化
			// @tag val => ...
			enum TagType   tag    = tags[0];
			enum IndexType index  = ImplOf!ED.getIndex!(tags[0]);
			alias          params = Parameters!(F!(MemberTypes[index]));
			static assert(params.length > 0);
			enum bool isDefault  = false;
			enum bool isCatch    = false;
			enum bool isCallback = true;
			alias RetType = ReturnType!(F!(MemberTypes[index]));
		}
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


@safe pure @nogc nothrow unittest
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
	
	static assert(matchFuncInfo!(U, (@a int x) => x + 1).tag == a);
	static assert(!matchFuncInfo!(U, (@a int x) => x + 1).isDefault);
	static assert( matchFuncInfo!(U, (@a int x) => x + 1).isCallback);
	static assert(!matchFuncInfo!(U, (@a int x) => x + 1).isCatch);
	static assert(is(matchFuncInfo!(U, (@a int x) => x + 1).RetType == int));
	
	static assert(matchFuncInfo!(U, (@a x) => x + 1).tag == a);
	static assert(!matchFuncInfo!(U, (@a x) => x + 1).isDefault);
	static assert( matchFuncInfo!(U, (@a x) => x + 1).isCallback);
	static assert(!matchFuncInfo!(U, (@a x) => x + 1).isCatch);
	static assert(is(matchFuncInfo!(U, (@a x) => x + 1).RetType == int));
	
	static assert(matchFuncInfo!(U, (@b x) => x ~ "x").tag == b);
	static assert(!matchFuncInfo!(U, (@b x) => x ~ "x").isDefault);
	static assert( matchFuncInfo!(U, (@b x) => x ~ "x").isCallback);
	static assert(!matchFuncInfo!(U, (@b x) => x ~ "x").isCatch);
	static assert(is(matchFuncInfo!(U, (@b x) => x ~ "x").RetType == string));
	
	static assert(matchFuncInfo!(U, other => "x").tag == ImplOf!U.notfoundTag);
	static assert( matchFuncInfo!(U, other => "x").isDefault);
	static assert(!matchFuncInfo!(U, other => "x").isCallback);
	static assert(!matchFuncInfo!(U, other => "x").isCatch);
	static assert(is(matchFuncInfo!(U, other => "x").RetType == string));
}

private template matchInfo(MU, Funcs...)
if (isManagedUnion!MU)
{
	alias IndexType   = ImplOf!MU.IndexType;
	alias TagType     = ImplOf!MU.TagType;
	alias notfoundTag = ImplOf!MU.notfoundTag;
	
	enum bool isDefault(alias F)     = matchFuncInfo!(MU, F).isDefault;
	enum bool isCatch(alias F)       = matchFuncInfo!(MU, F).isCatch;
	enum bool isCallback(alias F)    = matchFuncInfo!(MU, F).isCallback;
	enum bool isMatchFunc(alias F)   = matchFuncInfo!(MU, F).isMatchFunction;
	enum TagType getTag(alias F)     = matchFuncInfo!(MU, F).tag;
	enum IndexType getIndex(alias F) = matchFuncInfo!(MU, F).index;
	alias getParams(alias F)         = matchFuncInfo!(MU, F).params;
	alias getRetType(alias F)        = matchFuncInfo!(MU, F).RetType;
	
	alias RetType           = CommonType!(staticMap!(getRetType, Funcs));
	enum bool canMatch      = allSatisfy!(isMatchFunc, Funcs) && !is(returnType == void);
	enum size_t defaultIdx  = staticIndexOf!(true, staticMap!(isDefault, Funcs));
	enum bool hasDefault    = defaultIdx != -1;
	alias callbacks         = Filter!(isCallback, Funcs);
	alias catches           = Filter!(isCatch, Funcs);
	enum bool hasCatch      = catches.length;
	
	alias callbackTags                 = staticMap!(getTag, callbacks);
	enum bool isCallbackTag(TagType t) = staticIndexOf!(t, callbackTags) != -1;
	alias defaultTags                  = Filter!(templateNot!isCallbackTag, ImplOf!MU.allTags);
	
	// コールバックはメンバの数以下しかかけない
	static assert(callbacks.length <= ImplOf!MU.memberCount);
	// コールバックがメンバ全部に対応して書かれている場合はデフォルト不要
	static if (callbacks.length == ImplOf!MU.memberCount)
		static assert(!hasDefault);
	// コールバックがメンバ全部に対応して書かれていない場合はデフォルトが必須
	static if (callbacks.length < ImplOf!MU.memberCount)
		static assert(hasDefault);
	// デフォルト関数は1追加
	static assert(Filter!(isDefault, Funcs).length <= 1);
}


@safe pure @nogc nothrow unittest
{
	import std.exception;
	import std.conv: ConvException;
	import voile.misc: nogcEnforce;
	alias U = TypeEnum!(int, short, long);
	U dat;
	static assert(dat.getInstance()._inst.sizeof == long.sizeof);
	static assert(!TypeImplOf!U.hasType!char);
	static assert(TypeImplOf!U.hasType!short);
	static assert(TypeImplOf!U.getTypeIndex!short == 1);
	static assert(TypeImplOf!U.getAssignableIndex!short == 1);
	static assert(TypeImplOf!U.getAssignableIndex!long  == 2);
	static assert(TypeImplOf!U.isAssignable!byte);
	static assert(TypeImplOf!U.getAssignableIndex!byte  == 0);
	static assert(!TypeImplOf!U.hasType!char);
	
	static assert(TypeEnum!(ulong, long, uint, int).sizeof == TypeEnum!(ubyte, byte, ushort, long).sizeof);
	
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
		(long x)      => nogcEnforce(0));
	static assert(MatchInfo4.canMatch);
	static assert(MatchInfo4.hasDefault);
	static assert(MatchInfo4.hasCatch);
	static assert(MatchInfo4.defaultIdx == 1);
	static assert(is(MatchInfo4.RetType == int));
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
		pragma(inline) auto ref matchImpl(TMU)(return ref TMU dat)
		if (is(Unqual!TMU == MU))
		{
			alias qOf = QualifierOf!TMU;
			static if (minfo.hasDefault)
			{
				final switch (dat.getInstance()._impl._tag)
				{
				static foreach (F; minfo.callbacks) case minfo.getTag!F:
					return F(cast(qOf!(minfo.getParams!F[0]))(ref () @trusted 
						=> *cast(minfo.getParams!F[0]*)&dat.getInstance()._impl._inst.tupleof[minfo.getIndex!F])());
				case dat.getInstance()._impl.notfoundTag:
				static foreach (tag; minfo.defaultTags) case tag:
					static if (isCallable!(Funcs[minfo.defaultIdx]))
						return Funcs[minfo.defaultIdx]();
					else static if (__traits(isTemplate, Funcs[minfo.defaultIdx]))
						return Funcs[minfo.defaultIdx](dat.getInstance()._impl._inst.tupleof[dat.getInstance()._impl.getIndex!tag]);
					else
						return Funcs[minfo.defaultIdx];
				}
			}
			else
			{
				final switch (dat.getInstance()._impl._tag)
				{
				static foreach (F; minfo.callbacks) case minfo.getTag!F:
					return F(dat.getInstance()._impl._inst.tupleof[minfo.getIndex!F]);
				}
			}
		}
		
		// 関数本体
		pragma(inline) auto ref match(ref MU dat)
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
///
@safe pure @nogc nothrow unittest
{
	import std.exception;
	import std.conv: ConvException;
	import voile.misc: nogcEnforce;
	alias U = TypeEnum!(int, short, long);
	U dat;
	
	// マッチ関数を呼び出し
	dat.set!0 = 1;
	assert(dat.match!(
		(int x)  => x + 1, /* call */
		()       => 50,
		(long x) => x + 100) == 2);
	
	// デフォルトを設定できる(empty || どれにもヒットしない)
	dat.clear();
	assert(dat.match!(
		(int x)  => x + 1,
		()       => 50, /* call */
		(long x) => x + 100) == 50);
	// 例外をキャッチできる
	dat = cast(long)5;
	assert(dat.match!(
		(Exception e) => 100, /* call 2 */
		other         => 50,
		(long x)      => nogcEnforce(0)/* call 1 */) == 100);
}

///
@safe pure @nogc nothrow unittest
{
	enum E { @data!int x, @data!string str }
	mixin EnumMemberAlieses!E;
	
	alias ED = Endata!E;
	ED dat;
	
	// マッチ関数を呼び出し 引数に Data!tag を指定することでマッチ対象指定
	dat.x = 100;
	assert(dat.match!(
		(Data!x x) => x + 11 /* call */,
		()          => 10) == 111);
	// マッチ関数を呼び出し 引数に @tag を指定することでマッチ対象指定
	dat.str = "test";
	assert(dat.match!(
		(@str x) => (cast(string)x).length + 11,
		other    => 10) == 4 + 11);
}

@safe pure @nogc nothrow unittest
{
	import std.exception;
	import std.datetime: SysTime;
	import std.conv: ConvException;
	import voile.misc: nogcEnforce;
	struct A
	{
		int a;
		string b;
		int[] val;
		SysTime tim;
	}
	alias U = TypeEnum!(int, short, long, A);
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
	
	dat = A(10, "test");
	assert(dat.match!(
		(int x)  => x + 1,
		(A a)    => a.a + 10,
		()       => 50,
		(long x) => x + 100) == 20);
	
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

