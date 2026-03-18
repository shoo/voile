/*******************************************************************************
 * UDA
 */
module voile.attr;


import std.traits;
import std.meta;

// from phobos private template in std.traits
private template isDesiredUDA(alias attribute)
{
	template isDesiredUDA(alias toCheck)
	{
		static if (is(typeof(attribute)) && !__traits(isTemplate, attribute))
		{
			static if (__traits(compiles, toCheck == attribute))
				enum isDesiredUDA = toCheck == attribute;
			else
				enum isDesiredUDA = false;
		}
		else static if (is(typeof(toCheck)))
		{
			static if (__traits(isTemplate, attribute))
				enum isDesiredUDA =  isInstanceOf!(attribute, typeof(toCheck));
			else
				enum isDesiredUDA = is(typeof(toCheck) == attribute);
		}
		else static if (__traits(isTemplate, attribute))
			enum isDesiredUDA = isInstanceOf!(attribute, toCheck);
		else
			enum isDesiredUDA = is(toCheck == attribute);
	}
}

/*******************************************************************************
 * 関数のパラメータに付与されたUDAを取り出す。
 * 
 * Params:
 *      Func = 関数
 *      i    = 引数の番号(最初の引数は0番目)
 *      attr = UDAの種類を指定できます(指定しないとすべて返します)
 * Returns:
 *      UDAのタプルが返ります
 */
template getParameterUDAs(alias Func, size_t i)
{
	static if (__traits(compiles, { static assert(__traits(getAttributes, Parameters!Func[i]).length > 0); }))
	{
		alias getParameterUDAs = __traits(getAttributes, Parameters!Func[i]);
	}
	else static if (__traits(compiles, __traits(getAttributes, Parameters!Func[i..i+1])))
	{
		alias getParameterUDAs = __traits(getAttributes, Parameters!Func[i..i+1]);
	}
	else
	{
		alias getParameterUDAs = AliasSeq!();
	}
}
/// ditto
alias getParameterUDAs(alias Func, size_t i, alias attr) = Filter!(isDesiredUDA!attr, getParameterUDAs!(Func, i));
///
@safe @nogc nothrow pure unittest
{
	@(30) struct S {}
	enum Test;
	alias lambda = (@(10) int x, @(15) @(Test) long y, int z, S s) => x;
	
	alias uda1 = getParameterUDAs!(lambda, 0);
	static assert(uda1.length == 1);
	static assert(uda1[0] == 10);
	alias uda2 = getParameterUDAs!(lambda, 1);
	static assert(uda2.length == 2);
	static assert(uda2[0] == 15);
	static assert(is(uda2[1] == Test));
	alias uda3 = getParameterUDAs!(lambda, 2);
	static assert(uda3.length == 0);
	alias uda4 = getParameterUDAs!(lambda, 3);
	static assert(uda4.length == 1);
	static assert(uda4[0] == 30);
	
	static assert(getParameterUDAs!(lambda, 0, int).length  == 1);
	static assert(getParameterUDAs!(lambda, 0, Test).length == 0);
	static assert(getParameterUDAs!(lambda, 1, Test).length == 1);
}


/*******************************************************************************
 * 関数のパラメータに付与されたUDAのうち、型についたUDAを取り出す。
 * 
 * Params:
 *      Func = 関数
 *      i    = 引数の番号(最初の引数は0番目)
 *      attr = UDAの種類を指定できます(指定しないとすべて返します)
 * Returns:
 *      UDAのタプルが返ります
 */
template getParameterTypeUDAs(alias Func, size_t i)
{
	static if (__traits(compiles, __traits(getAttributes, Parameters!Func[i])))
	{
		alias getParameterTypeUDAs = __traits(getAttributes, Parameters!Func[i]);
	}
	else
	{
		alias getParameterTypeUDAs = AliasSeq!();
	}
}
/// ditto
alias getParameterTypeUDAs(alias Func, size_t i, alias attr)
	= Filter!(isDesiredUDA!attr, getParameterTypeUDAs!(Func, i));
///
@safe @nogc nothrow pure unittest
{
	@(30) struct S {}
	enum Test;
	alias lambda = (@(10) int x, @(15) @(Test) long y, int z, S s) => x;
	
	alias uda1 = getParameterTypeUDAs!(lambda, 0);
	static assert(uda1.length == 0);
	alias uda2 = getParameterTypeUDAs!(lambda, 1);
	static assert(uda2.length == 0);
	alias uda3 = getParameterTypeUDAs!(lambda, 2);
	static assert(uda3.length == 0);
	alias uda4 = getParameterTypeUDAs!(lambda, 3);
	static assert(uda4.length == 1);
	static assert(uda4[0] == 30);
}

/*******************************************************************************
 * 関数のパラメータに付与されたUDAのうち、引数についたUDAを取り出す。
 * 
 * Params:
 *      Func = 関数
 *      i    = 引数の番号(最初の引数は0番目)
 *      attr = UDAの種類を指定できます(指定しないとすべて返します)
 * Returns:
 *      UDAのタプルが返ります
 */
template getParameterArgUDAs(alias Func, size_t i)
{
	enum bool notFoundInType(alias val) = staticIndexOf!(val, getParameterTypeUDAs!(Func, i)) == -1;
	alias getParameterArgUDAs = Filter!(notFoundInType, getParameterUDAs!(Func, i));
}
/// ditto
alias getParameterArgUDAs(alias Func, size_t i, alias attr) = Filter!(isDesiredUDA!attr, getParameterArgUDAs!(Func, i));
///
@safe @nogc nothrow pure unittest
{
	@(30) struct S {}
	enum Test;
	alias lambda = (@(10) int x, @(15) @(Test) long y, int z, S s) => x;
	
	alias uda1 = getParameterArgUDAs!(lambda, 0);
	static assert(uda1.length == 1);
	static assert(uda1[0] == 10);
	alias uda2 = getParameterArgUDAs!(lambda, 1);
	static assert(uda2.length == 2);
	static assert(uda2[0] == 15);
	static assert(is(uda2[1] == Test));
	alias uda3 = getParameterArgUDAs!(lambda, 2);
	static assert(uda3.length == 0);
	alias uda4 = getParameterArgUDAs!(lambda, 3);
	static assert(uda4.length == 0);
	
	static assert(getParameterUDAs!(lambda, 0, int).length  == 1);
	static assert(getParameterUDAs!(lambda, 0, Test).length == 0);
	static assert(getParameterUDAs!(lambda, 1, Test).length == 1);
}


/*******************************************************************************
 * 関数のパラメータにUDAが付与されているか確認します
 * 
 * Params:
 *      Func = 関数
 *      i    = 引数の番号(最初の引数は0番目)
 *      attr = チェックするUDA
 * Returns:
 *      UDAがあったらtrue
 */
enum bool hasParameterUDA(alias Func, size_t i, alias attr) = getParameterUDAs!(Func, i, attr).length != 0;
///
@safe @nogc nothrow pure unittest
{
	@(30) struct S {}
	enum Test;
	alias lambda = (@(10) int x, @(15) @Test long y, int z, S s) => x;
	
	static assert( hasParameterUDA!(lambda, 0, 10));
	static assert(!hasParameterUDA!(lambda, 0, 15));
	static assert( hasParameterUDA!(lambda, 1, 15));
	static assert( hasParameterUDA!(lambda, 1, Test));
	static assert(!hasParameterUDA!(lambda, 2, 15));
	static assert( hasParameterUDA!(lambda, 3, 30));
}


/*******************************************************************************
 * 関数のパラメータに付与されたUDAのうち、型にUDAがついているか確認します
 * 
 * Params:
 *      Func = 関数
 *      i    = 引数の番号(最初の引数は0番目)
 *      attr = チェックするUDA
 * Returns:
 *      UDAがあったらtrue
 */
enum bool hasParameterTypeUDA(alias Func, size_t i, alias attr) = getParameterTypeUDAs!(Func, i, attr).length != 0;
///
@safe @nogc nothrow pure unittest
{
	@(30) struct S {}
	enum Test;
	alias lambda = (@(10) int x, @(15) @Test long y, int z, S s) => x;
	
	static assert(!hasParameterTypeUDA!(lambda, 0, 10));
	static assert(!hasParameterTypeUDA!(lambda, 0, 15));
	static assert(!hasParameterTypeUDA!(lambda, 1, 15));
	static assert(!hasParameterTypeUDA!(lambda, 1, Test));
	static assert(!hasParameterTypeUDA!(lambda, 2, 15));
	static assert( hasParameterTypeUDA!(lambda, 3, 30));
}


/*******************************************************************************
 * 関数のパラメータに付与されたUDAのうち、引数にUDAがついているか確認します
 * 
 * Params:
 *      Func = 関数
 *      i    = 引数の番号(最初の引数は0番目)
 *      attr = チェックするUDA
 * Returns:
 *      UDAがあったらtrue
 */
enum bool hasParameterArgUDA(alias Func, size_t i, alias attr) = getParameterArgUDAs!(Func, i, attr).length != 0;
///
@safe @nogc nothrow pure unittest
{
	@(30) struct S {}
	enum Test;
	alias lambda = (@(10) int x, @(15) @Test long y, int z, S s) => x;
	
	static assert( hasParameterArgUDA!(lambda, 0, 10));
	static assert(!hasParameterArgUDA!(lambda, 0, 15));
	static assert( hasParameterArgUDA!(lambda, 1, 15));
	static assert( hasParameterArgUDA!(lambda, 1, Test));
	static assert(!hasParameterArgUDA!(lambda, 2, 15));
	static assert(!hasParameterArgUDA!(lambda, 3, 30));
}


private enum Ignore {init}

/*******************************************************************************
 * Attribute marking ignore data
 */
enum Ignore ignore = Ignore.init;

///
enum bool hasIgnore(alias value) = hasUDA!(value, Ignore);

///
@safe unittest
{
	struct A { int test; @ignore int foo; }
	struct B { int test; }
	A a;
	B b;
	static assert(!hasIgnore!(a.test));
	static assert(!hasIgnore!(b.test));
	static assert( hasIgnore!(a.foo));
}

private struct IgnoreIf(alias func) {}
/*******************************************************************************
 * Attribute marking conditional ignore data
 */
alias ignoreIf(alias func) = IgnoreIf!func;

///
enum bool isIgnoreIf(alias uda) = isInstanceOf!(IgnoreIf, uda);
///
template hasIgnoreIf(alias symbol, Args...)
{
	static if (Args.length == 0)
	{
		enum bool hasIgnoreIf = Filter!(isIgnoreIf, __traits(getAttributes, symbol)).length > 0;
	}
	else
	{
		// シンボルからUDAを取り出す
		alias udas = Filter!(isIgnoreIf, __traits(getAttributes, symbol));
		enum bool isParameterMatch(alias func) = __traits(compiles, func(staticMap!(lvalueOf, Args)));
		enum bool isUdaMatch(alias uda) = isParameterMatch!(TemplateArgsOf!uda);
		enum bool hasIgnoreIf = Filter!(isUdaMatch, udas).length > 0;
	}
}
///
template getPredIgnoreIf(alias value, Args...)
{
	static if (isIgnoreIf!value)
	{
		// UDAから関数を取り出す
		alias getPredIgnoreIf = TemplateArgsOf!value[0];
	}
	else
	{
		// シンボルからUDAを取り出す
		alias udas = Filter!(isIgnoreIf, __traits(getAttributes, value));
		// UDAから関数を取り出す
		static if (Args.length == 0)
		{
			// 引数0の場合は先頭
			alias getPredIgnoreIf = TemplateArgsOf!(udas[0])[0];
		}
		else
		{
			// 引数ありの場合は、引数を確認
			enum bool isParameterMatch(alias func) = __traits(compiles, func(staticMap!(lvalueOf, Args)));
			enum bool isUdaMatch(alias uda) = isParameterMatch!(TemplateArgsOf!uda);
			alias getPredIgnoreIf = TemplateArgsOf!(Filter!(isUdaMatch, udas)[0])[0];
		}
	}
}

@safe unittest
{
	struct Data
	{
		@ignoreIf!((int a) => a == 10)
		@ignoreIf!((int[] a) => a.length == 2)
		int x;
	}
	static assert(hasIgnoreIf!(Data.x));
	static assert(hasIgnoreIf!(Data.x, int));
	static assert(hasIgnoreIf!(Data.x, int[]));
	static assert(!hasIgnoreIf!(Data.x, string));
	static assert(getPredIgnoreIf!(Data.x)(10));
	static assert(!getPredIgnoreIf!(Data.x)(1));
	static assert(getPredIgnoreIf!(Data.x, int)(10));
	static assert(!getPredIgnoreIf!(Data.x, int)(1));
	static assert(getPredIgnoreIf!(Data.x, int[])([1, 2]));
	static assert(!getPredIgnoreIf!(Data.x, int[])([1]));
}

private enum Essential {init}

/*******************************************************************************
 * Attribute marking essential field
 */
enum Essential essential = Essential.init;

///
enum bool hasEssential(alias value) = hasUDA!(value, Essential);

///
@safe unittest
{
	struct A { int test; @essential int foo; }
	struct B { int test; }
	A a;
	B b;
	static assert(!hasEssential!(a.test));
	static assert(!hasEssential!(b.test));
	static assert( hasEssential!(a.foo));
}


private enum Key {init}

/*******************************************************************************
 * Attribute marking essential field
 */
enum Key key = Key.init;

///
enum bool hasKey(alias value) = hasUDA!(value, Key);

///
enum bool isKeyMember(T, string member) = hasKey!(__traits(getMember, T, member));

///
alias getKeyMemberNames(T) = Filter!(ApplyLeft!(isKeyMember, T), FieldNameTuple!T);

///
enum bool hasKeyMember(T) = Filter!(ApplyLeft!(isKeyMember, T), FieldNameTuple!T).length != 0;

///
enum string getKeyMemberName(T) = Filter!(ApplyLeft!(isKeyMember, T), FieldNameTuple!T)[0];

///
@safe unittest
{
	struct A { int test; @key int foo; }
	struct B { int test; }
	A a;
	B b;
	static assert(!hasKey!(a.test));
	static assert(!hasKey!(b.test));
	static assert( hasKey!(a.foo));
	static assert( hasKeyMember!A);
	static assert(!hasKeyMember!B);
	static assert(getKeyMemberNames!A == AliasSeq!("foo"));
	static assert(getKeyMemberName!A == "foo");
}




private struct Name
{
	string name;
}

/*******************************************************************************
 * Attribute forcing field name
 */
Name name(string name) pure nothrow @nogc @safe
{
	return Name(name);
}
/// ditto
enum Name name(string n) = Name(n);

///
enum bool hasName(alias value) = hasUDA!(value, Name);

///
template getName(alias value)
if (hasName!value)
{
	enum string getName = getUDAs!(value, Name)[0].name;
}

///
@safe unittest
{
	struct A { int test; @name("test") int foo; }
	struct B { @name!"foo" int test; }
	A a;
	B b;
	static assert(!hasName!(a.test));
	static assert( hasName!(a.foo));
	static assert( hasName!(b.test));
	static assert(getName!(a.foo) == "test");
	static assert(getName!(b.test) == "foo");
}

private struct Value(T)
{
	T value;
}

/*******************************************************************************
 * Attribute forcing field value
 */
Value!T value(T)(T val) pure nothrow @nogc @safe
{
	return Value!T(val);
}
/// ditto
enum Value!(typeof(v)) value(alias v) = Value!(typeof(v))(v);

///
template hasValue(args...)
{
	static if (args.length == 1)
	{
		enum bool hasValue = hasUDA!(args[0], Value);
	}
	else static if (args.length == 2 && isType!(args[1]))
	{
		enum bool hasValue = hasUDA!(args[0], Value!(args[1]));
	}
	else static assert(0);
}

///
template getValues(args...)
{
	enum getVal(alias v) = v.value;
	static if (args.length == 1)
	{
		alias getValues = staticMap!(getVal, getUDAs!(args[0], Value));
	}
	else static if (args.length == 2 && isType!(args[1]))
	{
		alias getValues = staticMap!(getVal, getUDAs!(args[0], Value!(args[1])));
	}
	else static assert(0);
}

///
template getValue(alias value)
if (hasValue!value)
{
	enum getValue = getUDAs!(value, Value)[0].value;
}

///
@safe unittest
{
	struct A { int test; @value("test") int foo; }
	struct B { @value!1 int test; }
	A a;
	B b;
	static assert(!hasValue!(a.test));
	static assert( hasValue!(a.foo));
	static assert( hasValue!(b.test));
	static assert( hasValue!(b.test, int));
	static assert(getValue!(a.foo) == "test");
	static assert(getValue!(b.test) == 1);
}

///
struct ConvBy(alias T){}

///
alias convBy = ConvBy;

///
template isConvByAttr(alias Attr)
{
	static if (isInstanceOf!(convBy, Attr))
	{
		enum bool isConvByAttr = true;
	}
	else static if (is(typeof(Attr.to)) && is(typeof(Attr.from)))
	{
		enum bool isConvByAttr = true;
	}
	else
	{
		enum bool isConvByAttr = false;
	}
}

///
template getConvByAttr(alias Attr)
if (isConvByAttr!Attr)
{
	static if (isInstanceOf!(convBy, Attr))
	{
		alias getConvByAttr = TemplateArgsOf!(Attr)[0];
	}
	else static if (is(typeof(Attr.to)) && is(typeof(Attr.from)))
	{
		alias getConvByAttr = Attr;
	}
	else static assert(0);
}


///
alias ProxyList(alias value) = staticMap!(getConvByAttr, Filter!(isConvByAttr, __traits(getAttributes, value)));

///
template getConvBy(alias value)
{
	private alias _list = ProxyList!value;
	static assert(_list.length <= 1, `Only single serialization proxy is allowed`);
	alias getConvBy = _list[0];
}

///
template hasConvBy(alias value)
{
	private enum _listLength = ProxyList!value.length;
	static assert(_listLength <= 1, `Only single serialization proxy is allowed`);
	enum bool hasConvBy = _listLength == 1;
}

@safe unittest
{
	struct Proxy
	{
		static string to(ref int value) { return null; }
		static int from(string value)   { return 0; }
	}
	struct A
	{
		@convBy!Proxy int a;
		@(42) int b;
		@(42) @convBy!Proxy int c;
	}
	static assert(isConvByAttr!(__traits(getAttributes, A.a)));
	static assert(hasConvBy!(A.a));
	static assert(is(getConvBy!(A.a) == Proxy));
	
	static assert(!hasConvBy!(A.b));
	static assert(hasConvBy!(A.c));
}

private enum ConvStyle
{
	none,
	type1, // Ret dst = proxy.to(value);            / Val dst = proxy.from(value);
	type2, // Ret dst = proxy.to!Ret(value);        / Val dst = proxy.from!Val(value);
	type3, // Ret dst; proxy.to(value, dst);        / Val dst; proxy.from(value, dst);
	type4, // Ret dst = proxy(value);               / Val dst = proxy(value);
	type5, // Ret dst = proxy!Ret(value);           / Val dst = proxy!Val(value);
	type6, // Ret dst; proxy(value, dst);           / Val dst; proxy(value, dst);
	type7, // Ret dst = proxy.to(value, param);     / Val dst = proxy.from(value, param);
	type8, // Ret dst = proxy.to!Ret(value, param); / Val dst = proxy.from!Val(value, param);
	type9, // Ret dst; proxy.to(value, dst, param); / Val dst; proxy.from(value, dst, param);
	type10, // Ret dst = proxy(value, param);       / Val dst = proxy(value, param);
	type11, // Ret dst = proxy!Ret(value, param);   / Val dst = proxy!Val(value, param);
	type12, // Ret dst; proxy(value, dst, param);   / Val dst; proxy(value, dst, param);
}

private template getConvToStyle(alias value, Ret, P = void)
if (hasConvBy!value)
{
	alias proxy = getConvBy!value;
	alias Val   = typeof(value);
	static if (is(P == void) && is(typeof(proxy.to(lvalueOf!Val)) : Ret))
	{
		// Ret dst = proxy.to(value);
		enum getConvToStyle = ConvStyle.type1;
	}
	else static if (is(P == void) && is(typeof(proxy.to!Ret(lvalueOf!Val)) : Ret))
	{
		// Ret dst = proxy.to!Ret(value);
		enum getConvToStyle = ConvStyle.type2;
	}
	else static if (is(P == void)
	            && is(typeof(proxy.to(lvalueOf!Val, lvalueOf!Ret)))
	            && !is(typeof(proxy.to(lvalueOf!Val, rvalueOf!Ret))))
	{
		// Ret dst; proxy.to(value, dst);
		enum getConvToStyle = ConvStyle.type3;
	}
	else static if (is(P == void) && is(typeof(proxy(lvalueOf!Val)) : Ret))
	{
		// Ret dst = proxy(value);
		enum getConvToStyle = ConvStyle.type4;
	}
	else static if (is(P == void) && is(typeof(proxy!Ret(lvalueOf!Val)) : Ret))
	{
		// Ret dst = proxy!Ret(value);
		enum getConvToStyle = ConvStyle.type5;
	}
	else static if (is(P == void)
	            && is(typeof(proxy(lvalueOf!Val, lvalueOf!Ret)))
	            && !is(typeof(proxy(lvalueOf!Val, rvalueOf!Ret))))
	{
		// Ret dst; proxy(value, dst);
		enum getConvToStyle = ConvStyle.type6;
	}
	else static if (!is(P == void) && is(typeof(proxy.to(lvalueOf!Val, lvalueOf!P)) : Ret))
	{
		// Ret dst = proxy.to(value, param);
		enum getConvToStyle = ConvStyle.type7;
	}
	else static if (!is(P == void) && is(typeof(proxy.to!Ret(lvalueOf!Val, lvalueOf!P)) : Ret))
	{
		// Ret dst = proxy.to!Ret(value, param);
		enum getConvToStyle = ConvStyle.type8;
	}
	else static if (!is(P == void)
	            && is(typeof(proxy.to(lvalueOf!Val, lvalueOf!Ret, lvalueOf!P)))
	            && !is(typeof(proxy.to(lvalueOf!Val, rvalueOf!Ret, lvalueOf!P))))
	{
		// Ret dst; proxy.to(value, dst, param);
		enum getConvToStyle = ConvStyle.type9;
	}
	else static if (!is(P == void) && is(typeof(proxy(lvalueOf!Val, lvalueOf!P)) : Ret))
	{
		// Ret dst = proxy(value, param);
		enum getConvToStyle = ConvStyle.type10;
	}
	else static if (!is(P == void) && is(typeof(proxy!Ret(lvalueOf!Val, lvalueOf!P)) : Ret))
	{
		// Ret dst = proxy!Ret(value, param);
		enum getConvToStyle = ConvStyle.type11;
	}
	else static if (!is(P == void)
	            && is(typeof(proxy(lvalueOf!Val, lvalueOf!Ret, lvalueOf!P)))
	            && !is(typeof(proxy(lvalueOf!Val, rvalueOf!Ret, lvalueOf!P))))
	{
		// Ret dst; proxy(value, dst, param);
		enum getConvToStyle = ConvStyle.type12;
	}
	else
	{
		// no match
		enum getConvToStyle = ConvStyle.none;
	}
}

///
template canConvTo(alias value, T, P = void)
{
	static if (hasConvBy!value)
	{
		static if (is(P == void))
		{
			enum bool canConvTo = 0
				|| getConvToStyle!(value, T, P) == ConvStyle.type1
				|| getConvToStyle!(value, T, P) == ConvStyle.type2
				|| getConvToStyle!(value, T, P) == ConvStyle.type3
				|| getConvToStyle!(value, T, P) == ConvStyle.type4
				|| getConvToStyle!(value, T, P) == ConvStyle.type5
				|| getConvToStyle!(value, T, P) == ConvStyle.type6;
		}
		else
		{
			enum bool canConvTo = 0
				|| getConvToStyle!(value, T, P) == ConvStyle.type7
				|| getConvToStyle!(value, T, P) == ConvStyle.type8
				|| getConvToStyle!(value, T, P) == ConvStyle.type9
				|| getConvToStyle!(value, T, P) == ConvStyle.type10
				|| getConvToStyle!(value, T, P) == ConvStyle.type11
				|| getConvToStyle!(value, T, P) == ConvStyle.type12;
		}
	}
	else
	{
		enum bool canConvTo = false;
	}
}


///
template convTo(alias value, Dst, P = void)
if (canConvTo!(value, Dst, P))
{
	alias proxy = getConvBy!value;
	alias Val   = typeof(value);
	enum convToStyle = getConvToStyle!(value, Dst, P);
	static if (convToStyle == ConvStyle.type1)
	{
		// Ret dst = proxy.to(value);
		static Dst convTo()(auto ref Val v)
		{
			return proxy.to(v);
		}
		static Dst convTo()(const auto ref Val v)
		{
			return proxy.to(v);
		}
	}
	else static if (convToStyle == ConvStyle.type2)
	{
		// Ret dst = proxy.to!Ret(value);
		static Dst convTo()(auto ref Val v)
		{
			return proxy.to!Dst(v);
		}
		static Dst convTo()(const auto ref Val v)
		{
			return proxy.to!Dst(v);
		}
	}
	else static if (convToStyle == ConvStyle.type3)
	{
		// Ret dst; proxy.to(value, dst);
		static Dst convTo()(auto ref Val v)
		{
			Dst dst = void;
			proxy.to(v, dst);
			return dst;
		}
		static Dst convTo()(const auto ref Val v)
		{
			Dst dst = void;
			proxy.to(v, dst);
			return dst;
		}
	}
	else static if (convToStyle == ConvStyle.type4)
	{
		// Ret dst = proxy(value);
		static Dst convTo()(auto ref Val v)
		{
			return proxy(v);
		}
		static Dst convTo()(const auto ref Val v)
		{
			return proxy(v);
		}
	}
	else static if (convToStyle == ConvStyle.type5)
	{
		// Ret dst = proxy!Ret(value);
		static Dst convTo()(auto ref Val v)
		{
			return proxy!Dst(v);
		}
		static Dst convTo()(const auto ref Val v)
		{
			return proxy!Dst(v);
		}
	}
	else static if (convToStyle == ConvStyle.type6)
	{
		// Ret dst; proxy(value, dst);
		static Dst convTo()(auto ref Val v)
		{
			Dst dst = void;
			proxy(v, dst);
			return dst;
		}
		static Dst convTo()(const auto ref Val v)
		{
			Dst dst = void;
			proxy(v, dst);
			return dst;
		}
	}
	else static if (convToStyle == ConvStyle.type7)
	{
		// Ret dst = proxy.to(value, param);
		static Dst convTo()(auto ref Val v, auto ref P param)
		{
			return proxy.to(v, param);
		}
		static Dst convTo()(const auto ref Val v, auto ref P param)
		{
			return proxy.to(v, param);
		}
	}
	else static if (convToStyle == ConvStyle.type8)
	{
		// Ret dst = proxy.to!Ret(value, param);
		static Dst convTo()(auto ref Val v, auto ref P param)
		{
			return proxy.to!Dst(v, param);
		}
		static Dst convTo()(const auto ref Val v, auto ref P param)
		{
			return proxy.to!Dst(v, param);
		}
	}
	else static if (convToStyle == ConvStyle.type9)
	{
		// Ret dst; proxy.to(value, dst, param);
		static Dst convTo()(auto ref Val v, auto ref P param)
		{
			Dst dst = void;
			proxy.to(v, dst, param);
			return dst;
		}
		static Dst convTo()(const auto ref Val v, auto ref P param)
		{
			Dst dst = void;
			proxy.to(v, dst, param);
			return dst;
		}
	}
	else static if (convToStyle == ConvStyle.type10)
	{
		// Ret dst = proxy(value, param);
		static Dst convTo()(auto ref Val v, auto ref P param)
		{
			return proxy(v, param);
		}
		static Dst convTo()(const auto ref Val v, auto ref P param)
		{
			return proxy(v, param);
		}
	}
	else static if (convToStyle == ConvStyle.type11)
	{
		// Ret dst = proxy!Ret(value, param);
		static Dst convTo()(auto ref Val v, auto ref P param)
		{
			return proxy!Dst(v, param);
		}
		static Dst convTo()(const auto ref Val v, auto ref P param)
		{
			return proxy!Dst(v, param);
		}
	}
	else static if (convToStyle == ConvStyle.type12)
	{
		// Ret dst; proxy(value, dst, param);
		static Dst convTo()(auto ref Val v, auto ref P param)
		{
			Dst dst = void; proxy(v, dst, param); return dst;
		}
		static Dst convTo()(const auto ref Val v, auto ref P param)
		{
			Dst dst = void; proxy(v, dst, param); return dst;
		}
	}
	else static assert(0);
}

///
template getConvFromStyle(alias value, Src, P = void)
if (hasConvBy!value)
{
	alias proxy = getConvBy!value;
	alias Val   = typeof(value);
	static if (is(P == void) && is(typeof(proxy.from(lvalueOf!Src)) : Val))
	{
		// Val dst = proxy.from(value);
		enum getConvFromStyle = ConvStyle.type1;
	}
	else static if (is(P == void) && is(typeof(proxy.from!Val(lvalueOf!Src)) : Val))
	{
		// Val dst = proxy.from!Val(value);
		enum getConvFromStyle = ConvStyle.type2;
	}
	else static if (is(P == void)
	            && is(typeof(proxy.from(lvalueOf!Src, lvalueOf!Val)))
	            && !is(typeof(proxy.from(lvalueOf!Src, rvalueOf!Val))))
	{
		// Val dst; proxy.from(value, dst);
		enum getConvFromStyle = ConvStyle.type3;
	}
	else static if (is(P == void) && is(typeof(proxy(lvalueOf!Src)) : Val))
	{
		// Val dst = proxy(value);
		enum getConvFromStyle = ConvStyle.type4;
	}
	else static if (is(P == void) && is(typeof(proxy!Val(lvalueOf!Src)) : Val))
	{
		// Val dst = proxy!Val(value);
		enum getConvFromStyle = ConvStyle.type5;
	}
	else static if (is(P == void)
	            && is(typeof(proxy(lvalueOf!Src, lvalueOf!Val)))
	            && !is(typeof(proxy(lvalueOf!Src, rvalueOf!Val))))
	{
		// Val dst; proxy(value, dst);
		enum getConvFromStyle = ConvStyle.type6;
	}
	else static if (!is(P == void) && is(typeof(proxy.from(lvalueOf!Src, lvalueOf!P)) : Val))
	{
		// Val dst = proxy.from(value, param);
		enum getConvFromStyle = ConvStyle.type7;
	}
	else static if (!is(P == void) && is(typeof(proxy.from!Val(lvalueOf!Src, lvalueOf!P)) : Val))
	{
		// Val dst = proxy.from!Val(value, param);
		enum getConvFromStyle = ConvStyle.type8;
	}
	else static if (!is(P == void)
	            && is(typeof(proxy.from(lvalueOf!Src, lvalueOf!Val, lvalueOf!P)))
	            && !is(typeof(proxy.from(lvalueOf!Src, rvalueOf!Val, lvalueOf!P))))
	{
		// Val dst; proxy.from(value, dst, param);
		enum getConvFromStyle = ConvStyle.type9;
	}
	else static if (!is(P == void) && is(typeof(proxy(lvalueOf!Src, lvalueOf!P)) : Val))
	{
		// Val dst = proxy(value, param);
		enum getConvFromStyle = ConvStyle.type10;
	}
	else static if (!is(P == void) && is(typeof(proxy!Val(lvalueOf!Src, lvalueOf!P)) : Val))
	{
		// Val dst = proxy!Val(value, param);
		enum getConvFromStyle = ConvStyle.type11;
	}
	else static if (!is(P == void)
	            && is(typeof(proxy(lvalueOf!Src, lvalueOf!Val, lvalueOf!P)))
	            && !is(typeof(proxy(lvalueOf!Src, rvalueOf!Val, lvalueOf!P))))
	{
		// Val dst; proxy(value, dst, param);
		enum getConvFromStyle = ConvStyle.type12;
	}
	else
	{
		// no match
		enum getConvFromStyle = ConvStyle.none;
	}
}

///
template canConvFrom(alias value, T, P = void)
{
	static if (hasConvBy!value)
	{
		static if (is(P == void))
		{
			enum bool canConvFrom = 0
				|| getConvFromStyle!(value, T, P) == ConvStyle.type1
				|| getConvFromStyle!(value, T, P) == ConvStyle.type2
				|| getConvFromStyle!(value, T, P) == ConvStyle.type3
				|| getConvFromStyle!(value, T, P) == ConvStyle.type4
				|| getConvFromStyle!(value, T, P) == ConvStyle.type5
				|| getConvFromStyle!(value, T, P) == ConvStyle.type6;
		}
		else
		{
			enum bool canConvFrom = 0
				|| getConvFromStyle!(value, T, P) == ConvStyle.type7
				|| getConvFromStyle!(value, T, P) == ConvStyle.type8
				|| getConvFromStyle!(value, T, P) == ConvStyle.type9
				|| getConvFromStyle!(value, T, P) == ConvStyle.type10
				|| getConvFromStyle!(value, T, P) == ConvStyle.type11
				|| getConvFromStyle!(value, T, P) == ConvStyle.type12;
		}
	}
	else
	{
		enum bool canConvFrom = false;
	}
}

///
template convFrom(alias value, Src, P = void)
if (canConvFrom!(value, Src, P))
{
	alias proxy = getConvBy!value;
	alias Val   = typeof(value);
	enum convFromStyle = getConvFromStyle!(value, Src, P);
	static if (convFromStyle == ConvStyle.type1)
	{
		// Val dst = proxy.from(value);
		static Val convFrom()(auto ref Src v)
		{
			return proxy.from(v);
		}
		static Val convFrom()(const auto ref Src v)
		{
			return proxy.from(v);
		}
	}
	else static if (convFromStyle == ConvStyle.type2)
	{
		// Val dst = proxy.from!Val(value);
		static Val convFrom()(auto ref Src v)
		{
			return proxy.from!Val(v);
		}
		static Val convFrom()(const auto ref Src v)
		{
			return proxy.from!Val(v);
		}
	}
	else static if (convFromStyle == ConvStyle.type3)
	{
		// Val dst; proxy.from(value, dst);
		static Val convFrom()(auto ref Src v)
		{
			Val dst = void; proxy.from(v, dst); return dst;
		}
		static Val convFrom()(const auto ref Src v)
		{
			Val dst = void; proxy.from(v, dst); return dst;
		}
	}
	else static if (convFromStyle == ConvStyle.type4)
	{
		// Val dst = proxy(value);
		static Val convFrom()(auto ref Src v)
		{
			return proxy(v);
		}
		static Val convFrom()(const auto ref Src v)
		{
			return proxy(v);
		}
	}
	else static if (convFromStyle == ConvStyle.type5)
	{
		// Val dst = proxy!Val(value);
		static Val convFrom()(auto ref Src v)
		{
			return proxy!Val(v);
		}
		static Val convFrom()(const auto ref Src v)
		{
			return proxy!Val(v);
		}
	}
	else static if (convFromStyle == ConvStyle.type6)
	{
		// Val dst; proxy(value, dst);
		static Val convFrom()(auto ref Src v)
		{
			Val dst = void;
			proxy(v, dst);
			return dst;
		}
		static Val convFrom()(const auto ref Src v)
		{
			Val dst = void;
			proxy(v, dst);
			return dst;
		}
	}
	else static if (convFromStyle == ConvStyle.type7)
	{
		// Val dst = proxy.from(value, param);
		static Val convFrom()(auto ref Src v, auto ref P param)
		{
			return proxy.from(v, param);
		}
		static Val convFrom()(const auto ref Src v, auto ref P param)
		{
			return proxy.from(v, param);
		}
	}
	else static if (convFromStyle == ConvStyle.type8)
	{
		// Val dst = proxy.from!Val(value, param);
		static Val convFrom()(auto ref Src v, auto ref P param)
		{
			return proxy.from!Val(v, param);
		}
		static Val convFrom()(const auto ref Src v, auto ref P param)
		{
			return proxy.from!Val(v, param);
		}
	}
	else static if (convFromStyle == ConvStyle.type9)
	{
		// Val dst; proxy.from(value, dst, param);
		static Val convFrom()(auto ref Src v, auto ref P param)
		{
			Val dst = void;
			proxy.from(v, dst, param);
			return dst;
		}
		static Val convFrom()(const auto ref Src v, auto ref P param)
		{
			Val dst = void;
			proxy.from(v, dst, param);
			return dst;
		}
	}
	else static if (convFromStyle == ConvStyle.type10)
	{
		// Val dst = proxy(value, param);
		static Val convFrom()(auto ref Src v, auto ref P param)
		{
			return proxy(v, param);
		}
		static Val convFrom()(const auto ref Src v, auto ref P param)
		{
			return proxy(v, param);
		}
	}
	else static if (convFromStyle == ConvStyle.type11)
	{
		// Val dst = proxy!Val(value, param);
		static Val convFrom()(auto ref Src v, auto ref P param)
		{
			return proxy!Val(v, param);
		}
		static Val convFrom()(const auto ref Src v, auto ref P param)
		{
			return proxy!Val(v, param);
		}
	}
	else static if (convFromStyle == ConvStyle.type12)
	{
		// Val dst; proxy(value, dst, param);
		static Val convFrom()(auto ref Src v, auto ref P param)
		{
			Val dst = void;
			proxy(v, dst, param);
			return dst;
		}
		static Val convFrom()(const auto ref Src v, auto ref P param)
		{
			Val dst = void;
			proxy(v, dst, param);
			return dst;
		}
	}
	else static assert(0);
}

///
template convertTo(alias value)
{
	alias proxy = getConvBy!value;
	alias Val   = typeof(value);
	static void convertTo(Dst)(auto ref Val src, ref Dst dst)
	if (canConvTo!(value, Dst))
	{
		enum convToStyle = getConvToStyle!(value, Dst);
		static if (convToStyle == ConvStyle.type1)
		{
			// Ret dst = proxy.to(value);
			dst = proxy.to(src);
		}
		else static if (convToStyle == ConvStyle.type2)
		{
			// Ret dst = proxy.to!Ret(value);
			dst = proxy.to!Dst(src);
		}
		else static if (convToStyle == ConvStyle.type3)
		{
			// Ret dst; proxy.to(value, dst);
			proxy.to(src, dst);
		}
		else static if (convToStyle == ConvStyle.type4)
		{
			// Ret dst = proxy(value);
			dst = proxy(src);
		}
		else static if (convToStyle == ConvStyle.type5)
		{
			// Ret dst = proxy!Ret(value);
			dst = proxy!Dst(src);
		}
		else static if (convToStyle == ConvStyle.type6)
		{
			// Ret dst; proxy(value, dst);
			proxy(src, dst);
		}
		else static assert(0);
	}
	static void convertTo(Dst, P)(auto ref Val src, ref Dst dst, auto ref P param)
	if (canConvTo!(value, Dst, P))
	{
		enum convToStyle = getConvToStyle!(value, Dst, P);
		static if (convToStyle == ConvStyle.type7)
		{
			// Ret dst = proxy.to(value, param);
			dst = proxy.to(src, param);
		}
		else static if (convToStyle == ConvStyle.type8)
		{
			// Ret dst = proxy.to!Ret(value, param);
			dst = proxy.to!Dst(src, param);
		}
		else static if (convToStyle == ConvStyle.type9)
		{
			// Ret dst; proxy.to(value, dst, param);
			proxy.to(src, dst, param);
		}
		else static if (convToStyle == ConvStyle.type10)
		{
			// Ret dst = proxy(value, param);
			dst = proxy(src, param);
		}
		else static if (convToStyle == ConvStyle.type11)
		{
			// Ret dst = proxy!Ret(value, param);
			dst = proxy!Dst(src, param);
		}
		else static if (convToStyle == ConvStyle.type12)
		{
			// Ret dst; proxy(value, dst, param);
			proxy(src, dst, param);
		}
		else static assert(0);
	}
	static void convertTo(Dst)(const auto ref Val src, ref Dst dst)
	if (canConvTo!(value, Dst))
	{
		enum convToStyle = getConvToStyle!(value, Dst);
		static if (convToStyle == ConvStyle.type1)
		{
			// Ret dst = proxy.to(value);
			dst = proxy.to(src);
		}
		else static if (convToStyle == ConvStyle.type2)
		{
			// Ret dst = proxy.to!Ret(value);
			dst = proxy.to!Dst(src);
		}
		else static if (convToStyle == ConvStyle.type3)
		{
			// Ret dst; proxy.to(value, dst);
			proxy.to(src, dst);
		}
		else static if (convToStyle == ConvStyle.type4)
		{
			// Ret dst = proxy(value);
			dst = proxy(src);
		}
		else static if (convToStyle == ConvStyle.type5)
		{
			// Ret dst = proxy!Ret(value);
			dst = proxy!Dst(src);
		}
		else static if (convToStyle == ConvStyle.type6)
		{
			// Ret dst; proxy(value, dst);
			proxy(src, dst);
		}
		else static assert(0);
	}
	static void convertTo(Dst, P)(const auto ref Val src, ref Dst dst, auto ref P param)
	if (canConvTo!(value, Dst, P))
	{
		enum convToStyle = getConvToStyle!(value, Dst, P);
		static if (convToStyle == ConvStyle.type7)
		{
			// Ret dst = proxy.to(value, param);
			dst = proxy.to(src, param);
		}
		else static if (convToStyle == ConvStyle.type8)
		{
			// Ret dst = proxy.to!Ret(value, param);
			dst = proxy.to!Dst(src, param);
		}
		else static if (convToStyle == ConvStyle.type9)
		{
			// Ret dst; proxy.to(value, dst, param);
			proxy.to(src, dst, param);
		}
		else static if (convToStyle == ConvStyle.type10)
		{
			// Ret dst = proxy(value, param);
			dst = proxy(src);
		}
		else static if (convToStyle == ConvStyle.type11)
		{
			// Ret dst = proxy!Ret(value, param);
			dst = proxy!Dst(src, param);
		}
		else static if (convToStyle == ConvStyle.type12)
		{
			// Ret dst; proxy(value, dst, param);
			proxy(src, dst, param);
		}
		else static assert(0);
	}
}

///
template convertFrom(alias value)
{
	alias proxy = getConvBy!value;
	alias Val   = typeof(value);
	static void convertFrom(Src)(auto ref Src src, ref Val dst)
	if (canConvFrom!(value, Src))
	{
		enum convFromStyle = getConvFromStyle!(value, Src);
		static if (convFromStyle == ConvStyle.type1)
		{
			// Val dst = proxy.from(value);
			dst = proxy.from(src);
		}
		else static if (convFromStyle == ConvStyle.type2)
		{
			// Val dst = proxy.from!Val(value);
			dst = proxy.from!Val(src);
		}
		else static if (convFromStyle == ConvStyle.type3)
		{
			// Val dst; proxy.from(value, dst);
			proxy.from(src, dst);
		}
		else static if (convFromStyle == ConvStyle.type4)
		{
			// Val dst = proxy(value);
			dst = proxy(src);
		}
		else static if (convFromStyle == ConvStyle.type5)
		{
			// Val dst = proxy!Val(value);
			dst = proxy!Val(src);
		}
		else static if (convFromStyle == ConvStyle.type6)
		{
			// Val dst; proxy(value, dst);
			proxy(src, dst);
		}
		else static assert(0);
	}
	static void convertFrom(Src, P)(auto ref Src src, ref Val dst, auto ref P param)
	if (canConvFrom!(value, Src, P))
	{
		enum convFromStyle = getConvFromStyle!(value, Src, P);
		static if (convFromStyle == ConvStyle.type7)
		{
			// Val dst = proxy.from(value, param);
			dst = proxy.from(src, param);
		}
		else static if (convFromStyle == ConvStyle.type8)
		{
			// Val dst = proxy.from!Val(value, param);
			dst = proxy.from!Val(src, param);
		}
		else static if (convFromStyle == ConvStyle.type9)
		{
			// Val dst; proxy.from(value, dst, param);
			proxy.from(src, dst, param);
		}
		else static if (convFromStyle == ConvStyle.type10)
		{
			// Val dst = proxy(value, param);
			dst = proxy(src, param);
		}
		else static if (convFromStyle == ConvStyle.type11)
		{
			// Val dst = proxy!Val(value, param);
			dst = proxy!Val(src, param);
		}
		else static if (convFromStyle == ConvStyle.type12)
		{
			// Val dst; proxy(value, dst, param);
			proxy(src, dst, param);
		}
		else static assert(0);
	}
	static void convertFrom(Src)(const auto ref Src src, ref Val dst)
	if (canConvFrom!(value, Src))
	{
		enum convFromStyle = getConvFromStyle!(value, Src);
		static if (convFromStyle == ConvStyle.type1)
		{
			// Val dst = proxy.from(value);
			dst = proxy.from(src);
		}
		else static if (convFromStyle == ConvStyle.type2)
		{
			// Val dst = proxy.from!Val(value);
			dst = proxy.from!Val(src);
		}
		else static if (convFromStyle == ConvStyle.type3)
		{
			// Val dst; proxy.from(value, dst);
			proxy.from(src, dst);
		}
		else static if (convFromStyle == ConvStyle.type4)
		{
			// Val dst = proxy(value);
			dst = proxy(src);
		}
		else static if (convFromStyle == ConvStyle.type5)
		{
			// Val dst = proxy!Val(value);
			dst = proxy!Val(src);
		}
		else static if (convFromStyle == ConvStyle.type6)
		{
			// Val dst; proxy(value, dst);
			proxy(src, dst);
		}
		else static assert(0);
	}
	static void convertFrom(Src, P)(const auto ref Src src, ref Val dst, auto ref P param)
	if (canConvFrom!(value, Src, P))
	{
		enum convFromStyle = getConvFromStyle!(value, Src, P);
		static if (convFromStyle == ConvStyle.type7)
		{
			// Val dst = proxy.from(value, param);
			dst = proxy.from(src, param);
		}
		else static if (convFromStyle == ConvStyle.type2)
		{
			// Val dst = proxy.from!Val(value, param);
			dst = proxy.from!Val(src, param);
		}
		else static if (convFromStyle == ConvStyle.type3)
		{
			// Val dst; proxy.from(value, dst, param);
			proxy.from(src, dst, param);
		}
		else static if (convFromStyle == ConvStyle.type4)
		{
			// Val dst = proxy(value, param);
			dst = proxy(src, param);
		}
		else static if (convFromStyle == ConvStyle.type5)
		{
			// Val dst = proxy!Val(value, param);
			dst = proxy!Val(src, param);
		}
		else static if (convFromStyle == ConvStyle.type6)
		{
			// Val dst; proxy(value, dst, param);
			proxy(src, dst, param);
		}
		else static assert(0);
	}
}


///
enum isConvertible(alias value, T, P = void) = canConvTo!(value, T, P) && canConvFrom!(value, T, P);


@system unittest
{
	import std.conv;
	alias toInt = std.conv.to!int;
	struct Proxy1
	{
		static string to(ref int value)
		{
			return text(value) ~ "1";
		}
		static int from(string value)
		{
			return toInt(value) + 111;
		}
	}
	struct Proxy2
	{
		static T to(T)(ref int value)
		{
			return text(value) ~ "2";
		}
		static T from(T)(string value)
		{
			return toInt(value) + 222;
		}
	}
	struct Proxy3
	{
		static void to(int value, ref string dst) @safe
		{
			dst = text(value) ~ "3";
		}
		static void from(string value, ref int dst) @safe
		{
			dst = toInt(value) + 333;
		}
	}
	static string proxy4to(int value) @safe
	{
		return text(value) ~ "4";
	}
	static int proxy4from(string value) @safe
	{
		return toInt(value) + 444;
	}
	static T proxy5to(T)(int value) @safe
	{
		return text(value) ~ "5";
	}
	static T proxy5from(T)(string value)
	{
		return toInt(value) + 555;
	}
	static void proxy6to(int src, ref string dst)
	{
		dst = text(src) ~ "6";
	}
	static void proxy6from(string src, ref int dst)
	{
		dst = toInt(src) + 666;
	}
	static void proxy7to(T)(int src, ref T dst)
	{
		dst = text(src) ~ "7";
	}
	static void proxy7from(T)(string src, ref T dst)
	{
		dst = toInt(src) + 777;
	}
	struct Proxy8
	{
		static void to(int src, ref int dst)
		{
			dst = 0;
		}
		static void to(int src, ref string dst)
		{
			dst = text(src) ~ "8";
		}
		static void from(string src, ref int dst)
		{
			dst = toInt(src) + 888;
		}
		static void from(string src, ref string dst)
		{
			dst = null;
		}
	}
	static void proxy9(int src)
	{
		
	}
	static string proxy10(int src)
	{
		return null;
	}
	struct Proxy11
	{
		string prefix;
		static string to(ref int value, ref Proxy11 p)
		{
			return p.prefix ~ text(value) ~ "1";
		}
		static int from(string value, ref Proxy11 p)
		{
			return toInt(p.prefix ~ value) + 111;
		}
	}
	struct Proxy12
	{
		string prefix;
		static T to(T)(ref int value, ref Proxy12 p)
		{
			return p.prefix ~ text(value) ~ "2";
		}
		static T from(T)(string value, ref Proxy12 p)
		{
			return toInt(p.prefix ~ value) + 222;
		}
	}
	struct Proxy13
	{
		string prefix;
		static void to(int value, ref string dst, ref Proxy13 p) @safe
		{
			dst = p.prefix ~ text(value) ~ "3";
		}
		static void from(string value, ref int dst, ref Proxy13 p) @safe
		{
			dst = toInt(p.prefix ~ value) + 333;
		}
	}
	static string proxy14to(int value, ref int p) @safe
	{
		return text(value, p) ~ "4";
	}
	static int proxy14from(string value, ref int p) @safe
	{
		return toInt(value) + 444 + p;
	}
	static T proxy15to(T)(int value, ref int p) @safe
	{
		return text(value, p) ~ "5";
	}
	static T proxy15from(T)(string value, ref int p)
	{
		return toInt(value) + 555 + p;
	}
	static void proxy16to(int src, ref string dst, ref int p)
	{
		dst = text(src, p) ~ "6";
	}
	static void proxy16from(string src, ref int dst, ref int p)
	{
		dst = toInt(src) + 666 + p;
	}
	static void proxy17to(T)(int src, ref T dst, ref int p)
	{
		dst = text(src, p) ~ "7";
	}
	static void proxy17from(T)(string src, ref T dst, ref int p)
	{
		dst = toInt(src) + 777 + p;
	}
	struct Proxy18
	{
		string prefix;
		static void to(int src, ref int dst, ref Proxy18 p)
		{
			dst = 0;
		}
		static void to(int src, ref string dst, ref Proxy18 p)
		{
			dst = p.prefix ~ text(src) ~ "8";
		}
		static void from(string src, ref int dst, ref Proxy18 p)
		{
			dst = toInt(src ~ p.prefix) + 888;
		}
		static void from(string src, ref string dst, ref Proxy18 p)
		{
			dst = null;
		}
	}
	static void proxy19(int src, ref int p)
	{
		
	}
	static string proxy20(int src, ref int p)
	{
		return null;
	}
	struct A
	{
		@convBy!Proxy1        int a;
		@convBy!Proxy2        int b;
		@convBy!Proxy3        int c;
		@convBy!proxy4to      int d1;
		@convBy!proxy5to      int e1;
		@convBy!proxy6to      int f1;
		@convBy!proxy7to      int g1;
		@convBy!(Proxy8.to)   int h1;
		@convBy!proxy4from    int d2;
		@convBy!proxy5from    int e2;
		@convBy!proxy6from    int f2;
		@convBy!proxy7from    int g2;
		@convBy!(Proxy8.from) int h2;
		@convBy!Proxy8        int h;
		@convBy!proxy9        int i;
		int j;
		@convBy!proxy10       int k;
		
		@convBy!Proxy11        int pa;
		@convBy!Proxy12        int pb;
		@convBy!Proxy13        int pc;
		@convBy!proxy14to      int pd1;
		@convBy!proxy15to      int pe1;
		@convBy!proxy16to      int pf1;
		@convBy!proxy17to      int pg1;
		@convBy!(Proxy18.to)   int ph1;
		@convBy!proxy14from    int pd2;
		@convBy!proxy15from    int pe2;
		@convBy!proxy16from    int pf2;
		@convBy!proxy17from    int pg2;
		@convBy!(Proxy18.from) int ph2;
		@convBy!Proxy18        int ph;
		@convBy!proxy19        int pi;
		int pj;
		@convBy!proxy20       int pk;
	}
	static assert(getConvToStyle!(A.a, string) == ConvStyle.type1);
	static assert(getConvToStyle!(A.b, string) == ConvStyle.type2);
	static assert(getConvToStyle!(A.c, string) == ConvStyle.type3);
	static assert(getConvToStyle!(A.d1, string) == ConvStyle.type4);
	static assert(getConvToStyle!(A.e1, string) == ConvStyle.type5);
	static assert(getConvToStyle!(A.f1, string) == ConvStyle.type6);
	static assert(getConvToStyle!(A.g1, string) == ConvStyle.type6);
	static assert(getConvToStyle!(A.h1, string) == ConvStyle.type6);
	static assert(getConvToStyle!(A.pa, string, Proxy11) == ConvStyle.type7);
	static assert(getConvToStyle!(A.pb, string, Proxy12) == ConvStyle.type8);
	static assert(getConvToStyle!(A.pc, string, Proxy13) == ConvStyle.type9);
	static assert(getConvToStyle!(A.pd1, string, int) == ConvStyle.type10);
	static assert(getConvToStyle!(A.pe1, string, int) == ConvStyle.type11);
	static assert(getConvToStyle!(A.pf1, string, int) == ConvStyle.type12);
	static assert(getConvToStyle!(A.pg1, string, int) == ConvStyle.type12);
	static assert(getConvToStyle!(A.ph1, string, Proxy18) == ConvStyle.type12);
	
	static assert(getConvFromStyle!(A.a, string) == ConvStyle.type1);
	static assert(getConvFromStyle!(A.b, string) == ConvStyle.type2);
	static assert(getConvFromStyle!(A.c, string) == ConvStyle.type3);
	static assert(getConvFromStyle!(A.d2, string) == ConvStyle.type4);
	static assert(getConvFromStyle!(A.e2, string) == ConvStyle.type5);
	static assert(getConvFromStyle!(A.f2, string) == ConvStyle.type6);
	static assert(getConvFromStyle!(A.g2, string) == ConvStyle.type6);
	static assert(getConvFromStyle!(A.h2, string) == ConvStyle.type6);
	static assert(getConvFromStyle!(A.pa, string, Proxy11) == ConvStyle.type7);
	static assert(getConvFromStyle!(A.pb, string, Proxy12) == ConvStyle.type8);
	static assert(getConvFromStyle!(A.pc, string, Proxy13) == ConvStyle.type9);
	static assert(getConvFromStyle!(A.pd2, string, int) == ConvStyle.type10);
	static assert(getConvFromStyle!(A.pe2, string, int) == ConvStyle.type11);
	static assert(getConvFromStyle!(A.pf2, string, int) == ConvStyle.type12);
	static assert(getConvFromStyle!(A.pg2, string, int) == ConvStyle.type12);
	static assert(getConvFromStyle!(A.ph2, string, Proxy18) == ConvStyle.type12);
	
	static assert(getConvToStyle!(A.h, string)   == ConvStyle.type3);
	static assert(getConvFromStyle!(A.h, string) == ConvStyle.type3);
	static assert(getConvToStyle!(A.i, string) == ConvStyle.none);
	static assert(!__traits(compiles, getConvToStyle!(A.j, string)));
	static assert( canConvTo!(A.a, string));
	static assert(!canConvTo!(A.i, string));
	static assert(!canConvTo!(A.j, string));
	static assert( canConvFrom!(A.a, string));
	static assert(!canConvFrom!(A.i, string));
	static assert(!canConvFrom!(A.j, string));
	static assert( isConvertible!(A.a, string));
	static assert(!isConvertible!(A.a, real));
	static assert( canConvTo!(A.k, string));
	static assert(!canConvFrom!(A.k, string));
	static assert(!isConvertible!(A.k, string));
	static assert(getConvToStyle!(A.ph, string, Proxy18)   == ConvStyle.type9);
	static assert(getConvFromStyle!(A.ph, string, Proxy18) == ConvStyle.type9);
	static assert(getConvToStyle!(A.i, string) == ConvStyle.none);
	static assert(!__traits(compiles, getConvToStyle!(A.pj, string, int)));
	static assert( canConvTo!(A.pa, string, Proxy11));
	static assert(!canConvTo!(A.pi, string, int));
	static assert(!canConvTo!(A.pj, string, int));
	static assert( canConvFrom!(A.pa, string, Proxy11));
	static assert(!canConvFrom!(A.pi, string, int));
	static assert(!canConvFrom!(A.pj, string, int));
	static assert( isConvertible!(A.pa, string, Proxy11));
	static assert(!isConvertible!(A.pa, real, Proxy11));
	static assert( canConvTo!(A.pk, string, int));
	static assert(!canConvFrom!(A.pk, string, int));
	static assert(!isConvertible!(A.pk, string, int));
	
	A foo;
	foo.a = 10;
	foo.b = 20;
	foo.c = 30;
	foo.d1 = 40;
	foo.e1 = 50;
	foo.f1 = 60;
	foo.g1 = 70;
	foo.h1 = 80;
	
	foo.pa = 110;
	foo.pb = 120;
	foo.pc = 130;
	foo.pd1 = 140;
	foo.pe1 = 150;
	foo.pf1 = 160;
	foo.pg1 = 170;
	foo.ph1 = 180;
	
	string str_a;
	string str_b;
	string str_c;
	string str_d1;
	string str_e1;
	string str_f1;
	string str_g1;
	string str_h1;
	
	assert(convTo!(foo.a, string)(foo.a) == "101");
	assert(convTo!(foo.b, string)(foo.b) == "202");
	assert(convTo!(foo.c, string)(foo.c) == "303");
	assert(convTo!(foo.d1, string)(foo.d1) == "404");
	assert(convTo!(foo.e1, string)(foo.e1) == "505");
	assert(convTo!(foo.f1, string)(foo.f1) == "606");
	assert(convTo!(foo.g1, string)(foo.g1) == "707");
	assert(convTo!(foo.h1, string)(foo.h1) == "808");
	
	assert(convTo!(foo.pa, string, Proxy11)(foo.pa, Proxy11("test")) == "test1101");
	assert(convTo!(foo.pb, string, Proxy12)(foo.pb, Proxy12("test")) == "test1202");
	assert(convTo!(foo.pc, string, Proxy13)(foo.pc, Proxy13("test")) == "test1303");
	assert(convTo!(foo.pd1, string, int)(foo.pd1, 10) == "140104");
	assert(convTo!(foo.pe1, string, int)(foo.pe1, 10) == "150105");
	assert(convTo!(foo.pf1, string, int)(foo.pf1, 10) == "160106");
	assert(convTo!(foo.pg1, string, int)(foo.pg1, 10) == "170107");
	assert(convTo!(foo.ph1, string, Proxy18)(foo.ph1, Proxy18("test")) == "test1808");
	
	convertTo!(foo.a )(foo.a,  str_a);
	convertTo!(foo.b )(foo.b,  str_b);
	convertTo!(foo.c )(foo.c,  str_c);
	convertTo!(foo.d1)(foo.d1, str_d1);
	convertTo!(foo.e1)(foo.e1, str_e1);
	convertTo!(foo.f1)(foo.f1, str_f1);
	convertTo!(foo.g1)(foo.g1, str_g1);
	convertTo!(foo.h1)(foo.h1, str_h1);
	
	assert(str_a  == "101");
	assert(str_b  == "202");
	assert(str_c  == "303");
	assert(str_d1 == "404");
	assert(str_e1 == "505");
	assert(str_f1 == "606");
	assert(str_g1 == "707");
	assert(str_h1 == "808");
	
	convertTo!(foo.pa )(foo.pa,  str_a, Proxy11("test"));
	convertTo!(foo.pb )(foo.pb,  str_b, Proxy12("test"));
	convertTo!(foo.pc )(foo.pc,  str_c, Proxy13("test"));
	convertTo!(foo.pd1)(foo.pd1, str_d1, 10);
	convertTo!(foo.pe1)(foo.pe1, str_e1, 10);
	convertTo!(foo.pf1)(foo.pf1, str_f1, 10);
	convertTo!(foo.pg1)(foo.pg1, str_g1, 10);
	convertTo!(foo.ph1)(foo.ph1, str_h1, Proxy18("test"));
	
	assert(str_a  == "test1101");
	assert(str_b  == "test1202");
	assert(str_c  == "test1303");
	assert(str_d1 == "140104");
	assert(str_e1 == "150105");
	assert(str_f1 == "160106");
	assert(str_g1 == "170107");
	assert(str_h1 == "test1808");
	
	assert(convFrom!(foo.a,  string)("1000") == 1111);
	assert(convFrom!(foo.b,  string)("1000") == 1222);
	assert(convFrom!(foo.c,  string)("1000") == 1333);
	assert(convFrom!(foo.d2, string)("1000") == 1444);
	assert(convFrom!(foo.e2, string)("1000") == 1555);
	assert(convFrom!(foo.f2, string)("1000") == 1666);
	assert(convFrom!(foo.g2, string)("1000") == 1777);
	assert(convFrom!(foo.h2, string)("1000") == 1888);
	
	assert(convFrom!(foo.pa,  string, Proxy11)("1000", Proxy11("10")) == 101111);
	assert(convFrom!(foo.pb,  string, Proxy12)("1000", Proxy12("10")) == 101222);
	assert(convFrom!(foo.pc,  string, Proxy13)("1000", Proxy13("10")) == 101333);
	assert(convFrom!(foo.pd2, string, int    )("1000", 10           ) == 1454);
	assert(convFrom!(foo.pe2, string, int    )("1000", 10           ) == 1565);
	assert(convFrom!(foo.pf2, string, int    )("1000", 10           ) == 1676);
	assert(convFrom!(foo.pg2, string, int    )("1000", 10           ) == 1787);
	assert(convFrom!(foo.ph2, string, Proxy18)("1000", Proxy18("10")) == 100898);
	
	convertFrom!(foo.a)(  "1000", foo.a  );
	convertFrom!(foo.b)(  "1000", foo.b  );
	convertFrom!(foo.c)(  "1000", foo.c  );
	convertFrom!(foo.d2)( "1000", foo.d2 );
	convertFrom!(foo.e2)( "1000", foo.e2 );
	convertFrom!(foo.f2)( "1000", foo.f2 );
	convertFrom!(foo.g2)( "1000", foo.g2 );
	convertFrom!(foo.h2)( "1000", foo.h2 );
	
	assert(foo.a  == 1111);
	assert(foo.b  == 1222);
	assert(foo.c  == 1333);
	assert(foo.d2 == 1444);
	assert(foo.e2 == 1555);
	assert(foo.f2 == 1666);
	assert(foo.g2 == 1777);
	assert(foo.h2 == 1888);
	
	convertFrom!(foo.pa)(  "1000", foo.pa,  Proxy11("10"));
	convertFrom!(foo.pb)(  "1000", foo.pb,  Proxy12("10"));
	convertFrom!(foo.pc)(  "1000", foo.pc,  Proxy13("10"));
	convertFrom!(foo.pd2)( "1000", foo.pd2, 10);
	convertFrom!(foo.pe2)( "1000", foo.pe2, 10);
	convertFrom!(foo.pf2)( "1000", foo.pf2, 10);
	convertFrom!(foo.pg2)( "1000", foo.pg2, 10);
	convertFrom!(foo.ph2)( "1000", foo.ph2, Proxy18("10"));
	
	assert(foo.pa  == 101111);
	assert(foo.pb  == 101222);
	assert(foo.pc  == 101333);
	assert(foo.pd2 == 1454);
	assert(foo.pe2 == 1565);
	assert(foo.pf2 == 1676);
	assert(foo.pg2 == 1787);
	assert(foo.ph2 == 100898);
}

@safe unittest
{
	import std.datetime, std.json;
	///
	static struct AttrConverter
	{
		///
		JSONValue function(in SysTime v) to;
		///
		SysTime function(in JSONValue v) from;
	}
	
	AttrConverter converter(SysTime function(in JSONValue) from, JSONValue function(in SysTime) to)
	{
		return AttrConverter(to, from);
	}
	static struct A
	{
		@converter(jv=>SysTime.fromISOExtString(jv.str), v =>JSONValue(v.toISOExtString()))
		SysTime time;
	}
	static assert(hasConvBy!(A.time));
	static assert(getConvToStyle!(A.time, JSONValue) == ConvStyle.type1);
	static assert(getConvFromStyle!(A.time, JSONValue) == ConvStyle.type1);
}
