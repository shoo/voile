/*******************************************************************************
 * 便利関数
 */
module voile.misc;


import core.exception;
import std.traits, std.typetuple, std.variant, std.sumtype, std.algorithm, std.range, std.array;

/*******************************************************************************
 * 
 */
auto ref assumeAttr(alias fn, alias attrs, Args...)(auto ref Args args)
if (isFunction!fn)
{
	alias Func = SetFunctionAttributes!(typeof(&fn), functionLinkage!fn, attrs);
//	if (!__ctfe)
//	{
//		alias dgTy = SetFunctionAttributes!(void function(string), "D", attrs);
//		debug { (cast(dgTy)&disp)(typeof(fn).stringof); }
//	}
	return (cast(Func)&fn)(args);
}

/// ditto
auto ref assumeAttr(alias fn, alias attrs, Args...)(auto ref Args args)
if (__traits(isTemplate, fn) && isCallable!(fn!Args))
{
	alias Func = SetFunctionAttributes!(typeof(&(fn!Args)), functionLinkage!(fn!Args), attrs);
//	if (!__ctfe)
//	{
//		alias dgTy = SetFunctionAttributes!(void function(string), "D", attrs);
//		debug { (cast(dgTy)&disp)(typeof(fn!Args).stringof); }
//	}
	return (cast(Func)&fn!Args)(args);
}

/// ditto
auto assumeAttr(alias attrs, Fn)(Fn t)
	if (isFunctionPointer!Fn || isDelegate!Fn)
{
	return cast(SetFunctionAttributes!(Fn, functionLinkage!Fn, attrs)) t;
}

/*******************************************************************************
 * 
 */
template getFunctionAttributes(T...)
{
	alias fn = T[0];
	static if (T.length == 1 && (isFunctionPointer!(T[0]) || isDelegate!(T[0])))
	{
		enum getFunctionAttributes = functionAttributes!fn;
	}
	else static if (!is(typeof(fn!(T[1..$]))))
	{
		enum getFunctionAttributes = functionAttributes!(fn);
	}
	else
	{
		enum getFunctionAttributes = functionAttributes!(fn!(T[1..$]));
	}
}

/*******************************************************************************
 * 
 */
auto ref assumePure(alias fn, Args...)(auto ref Args args)
{
	return assumeAttr!(fn, getFunctionAttributes!(fn, Args) | FunctionAttribute.pure_, Args)(args);
}

/// ditto
auto assumePure(T)(T t)
	if (isFunctionPointer!T || isDelegate!T)
{
	return assumeAttr!(getFunctionAttributes!T | FunctionAttribute.pure_)(t);
}

/*******************************************************************************
 * 
 */
auto ref assumeNogc(alias fn, Args...)(auto ref Args args)
{
	return assumeAttr!(fn, getFunctionAttributes!(fn, Args) | FunctionAttribute.nogc, Args)(args);
}

/// ditto
auto assumeNogc(T)(T t)
	if (isFunctionPointer!T || isDelegate!T)
{
	return assumeAttr!(getFunctionAttributes!T | FunctionAttribute.nogc)(t);
}


/*******************************************************************************
 * 
 */
auto ref assumeNothrow(alias fn, Args...)(auto ref Args args)
{
	return assumeAttr!(fn, getFunctionAttributes!(fn, Args) | FunctionAttribute.nothrow_, Args)(args);
}

/// ditto
auto assumeNothrow(T)(T t)
	if (isFunctionPointer!T || isDelegate!T)
{
	return assumeAttr!(getFunctionAttributes!T | FunctionAttribute.nothrow_)(t);
}



///
debug private void dispImpl(T...)(T args)
{
	import std.stdio, std.string;
	writeln(args);
}

///
debug void disp(T...)(T args) nothrow pure @nogc @trusted
{
	assumeAttr!(dispImpl!T, FunctionAttribute.nothrow_ | FunctionAttribute.pure_ | FunctionAttribute.nogc)(args);
}

private template AssumedUnsharedType(T)
{
	import std.traits;
	static if (is(T U == shared(U)))
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(U);
	}
	else static if (is(T U == const(shared(U))))
	{
		alias AssumedUnsharedType = const(AssumedUnsharedType!(U));
	}
	else static if (isPointer!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(pointerTarget!T)*;
	}
	else static if (isDynamicArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ForeachType!T)[];
	}
	else static if (isStaticArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ForeachType!T)[T.length];
	}
	else static if (isAssociativeArray!T)
	{
		alias AssumedUnsharedType = AssumedUnsharedType!(ValueType!T)[AssumedUnsharedType!(KeyType!T)];
	}
	else
	{
		alias AssumedUnsharedType = T;
	}
}

/*******************************************************************************
 * 
 */
auto ref assumeUnshared(T)(ref T x) @property
{
	return *cast(AssumedUnsharedType!(T)*)&x;
}

/*******************************************************************************
 * 
 */
auto ref assumeShared(T)(ref T x) @property
{
	return *cast(shared)&x;
}


/*******************************************************************************
 * 
 */
template nogcEnforce(E : Throwable = Exception)
if (is(typeof(new E(string.init, string.init, size_t.init)) : Throwable)
 || is(typeof(new E(string.init, size_t.init)) : Throwable))
{
	T nogcEnforce(T)(T value, string msg = null, string file = __FILE__, size_t line = __LINE__) @safe @nogc
	if (is(typeof({ if (!value) {} })))
	{
		if (!value) (() @trusted => assumePure!(nogcBailOut!E)(file, line, msg))();
		return value;
	}
}
/// ditto
T nogcEnforce(T, Dg, string file = __FILE__, size_t line = __LINE__)(T value, scope Dg dg) @safe @nogc
if (isSomeFunction!Dg && is(typeof(dg())) && is(typeof(() { if (!value) { } } )))
{
	if (!value) dg();
}

private void nogcBailOut(E)(string file, size_t line, string msg) @safe @nogc
{
	import std.conv: emplace;
	static void[__traits(classInstanceSize, E)] _nogcExceptionBuffer;
	static if (is(typeof(new E(string.init, string.init, size_t.init))))
	{
		throw emplace!E((() @trusted => cast(E)(_nogcExceptionBuffer.ptr))(), msg, file, line);
	}
	else static if (is(typeof(new E(string.init, size_t.init))))
	{
		throw emplace!E((() @trusted => cast(E)(_nogcExceptionBuffer.ptr))(), file, line);
	}
	else static assert(0);
}

@safe @nogc unittest
{
	import std.exception;
	long x = 10;
	try nogcEnforce(x, "xxx");
	catch (Exception e) assert(0);
	
	x = 0;
	try nogcEnforce(x, "xxx");
	catch (Exception e)
	{
		x = 1;
	}
	assert(x == 1);
	
}

/*******************************************************************************
 * 
 */
template TemplateSpecializedTypeTuple(T)
{
	static if (is(T: Temp!Params, alias Temp, Params...))
	{
		alias TemplateSpecializedTypeTuple = Params;
	}
	else
	{
		enum NoneTemplate { init }
		alias TemplateSpecializedTypeTuple = TypeTuple!(NoneTemplate);
	}
}

private template _isNotRefPSC(uint pcs)
{
	enum _isNotRefPSC = (pcs & ParameterStorageClass.ref_) == 0;
}


/*******************************************************************************
 * 
 */
CommonType!(staticMap!(ReturnType, T))
	variantSwitch(T...)(auto ref Variant var, T caseFunctions)
{
	enum isZeroLengthParameter(P) = staticMap!(Parameters, P).length == 0;
	static assert(allSatisfy!(isCallable, T),
		"variantSwitch ascepts only callable");
	foreach (i, t1; T)
	{
		alias a1 = Parameters!(t1);
		alias r1 = ReturnType!(t1);
		
		static if (i + 1 < T.length)
		{
			// 最後のcase function以外では引数が1つでVariantというcaseは認められない
			static assert(a1.length != 1 || !is( a1[0] == Variant ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
		}
		foreach (t2; T[i+1 .. $] )
		{
			alias a2 = ParameterTypeTuple!(t2);
			alias psc2 = ParameterStorageClassTuple!(t2);
			static assert( !is( a1 == a2 ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
			static assert(a1.length);
			static if (a2.length)
			{
				static assert(!isImplicitlyConvertible!( a2, a1 ),
					"case function with argument types " ~ a2.stringof ~
					" is hidden by " ~ a1.stringof );
			}
			alias PSC = ParameterStorageClass;
			static if (!allSatisfy!(_isNotRefPSC, psc2))
			{
				alias psc = ParameterStorageClassTuple!(variantSwitch);
				static assert(psc[0] & PSC.ref_);
			}
		}
	}
	foreach (fn; caseFunctions)
	{
		alias Args = Parameters!fn;
		alias psc2 = ParameterStorageClassTuple!fn;
		static if (Args.length == 0)
		{
			return fn();
		}
		else static if (is(Args[0] == Variant))
		{
			return fn(var);
		}
		else
		{
			static if (allSatisfy!(_isNotRefPSC, psc2))
			{
				if (var.convertsTo!(typeof(Args.init)))
				{
					return fn(var.get!(typeof(Args.init)));
				}
			}
			else
			{
				if (var.convertsTo!(typeof(Args.init)))
				{
					auto v = var.get!(typeof(Args.init));
					scope (exit) var = v;
					return fn(v);
				}
			}
		}
	}
	static if (staticMap!(Parameters, T).length > 0
	 && !anySatisfy!(isZeroLengthParameter, T)
	 && !is(staticMap!(Parameters, T)[$-1] == Variant))
		throw new SwitchError("No appropriate switch clause found");
}


@system unittest
{
	Variant var1 = 1;
	Variant var2 = 3.5;
	Variant var3 = "test";
	
	void test(Variant v)
	{
		variantSwitch(v,
		(ubyte a)
		{
			assert(0);
		},
		(int a)
		{
			assert(a == 1);
		},
		(double a)
		{
			assert(a == 3.5);
		}
		);
	}
	test(var1);
	test(var2);
	
	
	auto test2(Variant v)
	{
		return variantSwitch(v,
		(ubyte a)
		{
			assert(a);
			return 0;
		},
		(int a)
		{
			assert(a == 1);
			return 1;
		},
		(double a)
		{
			assert(a == 3.5);
			return 2;
		}
		);
	}
	assert(test2(var1) == 1);
	assert(test2(var2) == 2);
	
	
	auto test3(Variant v)
	{
		return variantSwitch(v,
		(ubyte a)
		{
			assert(a);
			return 0;
		},
		(int a)
		{
			assert(a == 1);
			return 1;
		},
		(double a)
		{
			assert(a == 3.5);
			return 2;
		},
		(Variant a)
		{
			return 3;
		}
		);
	}
	try
	{
		test(var3);
		assert(0);
	}
	catch (SwitchError)
	{
	}
	catch (Throwable e)
	{
		assert(0);
	}
	assert(test3(var3) == 3);
	
	
	auto test4(ref Variant v)
	{
		int x;
		variantSwitch(v,
		(ref int a)
		{
			assert(a == 1);
			x = 0;
			a = 10;
		},
		()
		{
			x = 1;
		}
		);
		return x;
	}
	
	assert(var1 == 1);
	assert(test4(var1) == 0);
	assert(var1 == 10);
	assert(test4(var3) == 1);
	var1 = 1;
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		(ubyte a)
		{
		},
		// !
		(Variant a)
		{
		},
		(double a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		// !
		{
		},
		(int a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		(ubyte a)
		{
			return 0;
		},
		// !
		(ubyte a)
		{
			return 0;
		},
		{
			return 1;
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(var1,
		(int a)
		{
			return 0;
		},
		// !
		(ubyte a)
		{
			return 0;
		},
		{
			return 1;
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		variantSwitch(v,
		(ubyte a)
		{
			return 0;
		},
		// !
		{
			return 1;
		},
		(ubyte a)
		{
			return 0;
		}
		);
	}));
	
	
}



/*******************************************************************************
 * 
 */
deprecated("castSwitch is now available in Phobos std.algorithm")
CommonType!(staticMap!(ReturnType, T))
	castSwitch(Base, T...)(Base inst, T caseFunctions)
{
	static assert(allSatisfy!(isCallable, T),
		"classSwitch ascepts only callable");
	foreach (i, t1; T)
	{
		alias a1 = ParameterTypeTuple!(t1);
		alias r1 = ReturnType!(t1);
		
		static if (i+1 < T.length)
		{
			// 最後じゃなければBaseに暗黙変換可能な型のみが許される
			// 必ず引数は1つとること
			static assert(a1.length == 1 && isImplicitlyConvertible!( a1[0], Base ),
				"case function with argument types " ~ a1.stringof ~ " occludes successive function" );
		}
		else
		{
			// 最後なら引数なしか、Baseに暗黙変換可能な型か、Baseが暗黙変換可能な型が許される
			static if (a1.length != 0)
			{
				static assert(isImplicitlyConvertible!( a1[0], Base ) || isImplicitlyConvertible!( Base, a1[0] ),
					"case function with argument types " ~ a1.stringof ~ " occludes successive function");
			}
		}
		foreach (t2; T[i+1 .. $] )
		{
			alias a2 = ParameterTypeTuple!(t2);
			// 同じ型があってはならない
			static assert( !is( a1 == a2 ),
				"case function with argument types " ~ a1.stringof ~
				" occludes successive function" );
			static assert(a1.length);
			static if (a2.length)
			{
				// 引数があるなら、あとに書かれたcaseの型が先に書かれたcaseの型に暗黙変換不可能
				static assert(!isImplicitlyConvertible!( a2, a1 ),
					"case function with argument types " ~ a2.stringof ~
					" is hidden by " ~ a1.stringof );
			}
		}
	}
	foreach (fn; caseFunctions)
	{
		alias Args = ParameterTypeTuple!fn;
		static if (Args.length == 0)
		{
			return fn();
		}
		else static if (isImplicitlyConvertible!( Base, Args[0]))
		{
			return fn(inst);
		}
		else
		{
			if (auto casted = cast(Args[0])inst)
			{
				return fn(casted);
			}
		}
	}
	throw new SwitchError("No appropriate switch clause found");
}

version(none) @system unittest
{
	class A
	{
	}
	class B: A
	{
	}
	class C
	{
	}
	
	A a = new A;
	B b = new B;
	A a_b = new B;
	C c = new C;
	
	int test(Object o)
	{
		int x;
		castSwitch(o,
		(B a)
		{
			x = 0;
		},
		(A a)
		{
			x = 1;
		},
		(C a)
		{
			x = 2;
		}
		);
		return x;
	}
	assert(test(a) == 1);
	assert(test(b) == 0);
	assert(test(c) == 2);
	
	auto test2(Object o)
	{
		return castSwitch(o,
		(B a)
		{
			return 0;
		},
		(A a)
		{
			return 1;
		},
		(C a)
		{
			return 2;
		}
		);
	}
	assert(test2(a) == 1);
	assert(test2(b) == 0);
	assert(test2(c) == 2);
	
	
	class D
	{
	}
	D d = new D;
	auto test3(Object o)
	{
		return castSwitch(o,
		(B a)
		{
			return 0;
		},
		(A a)
		{
			return 1;
		},
		(C a)
		{
			return 2;
		},
		(Object a)
		{
			return 3;
		}
		);
	}
	try
	{
		test(d);
		assert(0);
	}
	catch (SwitchError)
	{
	}
	catch (Throwable e)
	{
		assert(0);
	}
	assert(test3(d) == 3);
	
	
	auto test4(Object o)
	{
		int x;
		castSwitch(o,
		(A a)
		{
			x = 0;
		},
		()
		{
			x = 1;
		}
		);
		return x;
	}
	
	assert(test4(a) == 0);
	assert(test4(d) == 1);
	
	static assert(!__traits(compiles,
	{
		caseSwitch(a,
		// !
		(A a)
		{
		},
		(B a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		caseSwitch(a,
		// !
		{
		},
		(A a)
		{
		}
		);
	}));
	
	static assert(!__traits(compiles,
	{
		caseSwitch(a,
		(B a)
		{
			return 0;
		},
		// !
		{
			return 1;
		},
		(C a)
		{
			return 0;
		}
		);
	}));
	
}


private S indentRuntime(S)(S s, S indentStr = " ")
{
	auto app = appender!(S)();
	// Overflow is no problem for this line.
	app.reserve((s.length * 17)/16);
	
	immutable pend = s.ptr + s.length;
	auto p = s.ptr;
	auto pHead = p;
	
	void putLine()
	{
		assert(s.ptr <= pHead);
		assert(pHead <= p);
		assert(p <= pend);
		app.put(indentStr);
		app.put(pHead[0..p - pHead]);
		if (p !is pend)
		{
			pHead = p + 1;
		}
	}
	
	for (; p != pend; ++p)
	{
		if (*p == '\n')
		{
			putLine();
			app.put('\n');
		}
	}
	if (pHead != pend)
	{
		assert(p is pend);
		putLine();
	}
	return app.data;
}

private S indentCtfe(S)(S s, S indentStr = " ")
{
	import std.string;
	auto app = appender!(S)();
	
	auto lines = s.splitLines(KeepTerminator.yes);
	foreach (l; lines)
	{
		app.put(indentStr);
		app.put(l);
	}
	return app.data;
}


/*******************************************************************************
 * 
 */
S indent(S)(S s, S indentStr = "\t")
out(r)
{
	debug version(D_unittest)
		assert( r == s.indentCtfe(indentStr));
}
do
{
	return __ctfe ? s.indentCtfe(indentStr) : s.indentRuntime(indentStr);
}

@system unittest
{
	static assert(`<
		a b c
		d
			e
		f
			g
				h
	>`.indent() == `	<
			a b c
			d
				e
			f
				g
					h
		>`);
}

import std.stdio: File;

/***************************************************************************
 * 
 */
void truncate(ref File f, size_t fileSize = -1)
{
	ulong oldptr = -1;
	scope (exit)
	{
		if (oldptr != -1)
			f.seek(oldptr);
	}
	version (Windows)
	{
		import core.sys.windows.windows;
		if (fileSize != -1)
		{
			ulong p = f.tell;
			if (p != fileSize)
				oldptr = p;
			f.seek(fileSize);
		}
		SetEndOfFile(f.windowsHandle);
	}
	else version (Posix)
	{
		import core.sys.posix.unistd, core.sys.posix.sys.types;
		ftruncate(cast(int)f.getFP, cast(off_t)f.tell);
	}
}



/*******************************************************************************
 * 新しいパスを現在のパスの後ろに追加します
 */
void addPathAfter(string newpath)
{
	import std.process;
	if (auto path = environment.get("Path", null))
	{
		environment["Path"] = path ~ ";" ~ newpath;
		return;
	}
	if (auto path = environment.get("PATH", null))
	{
		environment["PATH"] = path ~ ";" ~ newpath;
		return;
	}
	if (auto path = environment.get("path", null))
	{
		environment["path"] = path ~ ";" ~ newpath;
		return;
	}
	environment["PATH"] = newpath;
}

/*******************************************************************************
 * 新しいパスを現在のパスの前に追加します
 */
void addPathBefore(string newpath)
{
	import std.process;
	if (auto path = environment.get("Path", null))
	{
		environment["Path"] = newpath ~ ";" ~ path;
		return;
	}
	if (auto path = environment.get("PATH", null))
	{
		environment["PATH"] = newpath ~ ";" ~ path;
		return;
	}
	if (auto path = environment.get("path", null))
	{
		environment["path"] = newpath ~ ";" ~ path;
		return;
	}
	environment["PATH"] = newpath;
}

/*******************************************************************************
 * MBS(ZeroNIL)文字列からUTF8に変換
 */
string fromMBS(in ubyte[] data, uint codePage = 0)
{
	version (Windows)
	{
		import std.windows.charset: fromMBSz;
		auto buf = data ~ 0;
		return fromMBSz(cast(immutable char*)buf.ptr, codePage);
	}
	else
	{
		// Windows以外では無視する。
		return cast(string)data.idup;
	}
}


/*******************************************************************************
 * UTF16(ZeroNIL)文字列からUTF8に変換
 */
string fromUTF16z(in wchar* data)
{
	import std.utf: toUTF8;
	const(wchar)* p = data;
	while (*p != '\0')
		++p;
	return toUTF8(data[0..(p - data)]);
}



/*******************************************************************************
 * UTF8からMBS(ZeroNIL)文字列に変換
 */
const(char)[] toMBS(in char[] data, uint codePage = 0)
{
	version (Windows)
	{
		import std.windows.charset: toMBSz;
		import core.stdc.string: strlen;
		auto dat = toMBSz(cast(string)data, codePage);
		return dat[0..strlen(dat)];
	}
	else
	{
		// Windows以外では無視する。
		return cast(string)data.idup;
	}
}


/*******************************************************************************
 * 
 */
enum MacroType
{
	/// $xxx, ${xxx}
	str,
	/// $(xxx)
	expr
}

/*******************************************************************************
 * Expands macro variables contained within a str
 */
T expandMacro(T, Func)(in T str, Func mapFunc)
	if (isSomeString!T
	&& isCallable!Func
	&& is(ReturnType!Func: bool)
	&& ParameterTypeTuple!Func.length >= 1
	&& is(T: ParameterTypeTuple!Func[0])
	&& (ParameterStorageClassTuple!Func[0] & ParameterStorageClass.ref_) == ParameterStorageClass.ref_)
{
	bool func(ref T arg, MacroType type, bool expandRecurse)
	{
		if (expandRecurse)
			arg = arg.expandMacroImpl!(T, func)();
		static if (ParameterTypeTuple!Func.length == 1)
		{
			return mapFunc(arg);
		}
		else
		{
			return mapFunc(arg, type);
		}
	}
	return str.expandMacroImpl!(T, func)();
}

/// ditto
T expandMacro(T, Func)(in T str, Func mapFunc)
	if (isSomeString!T
	&& isCallable!Func
	&& is(ReturnType!Func: T)
	&& ParameterTypeTuple!Func.length >= 1
	&& is(T: ParameterTypeTuple!Func[0]))
{
	bool func(ref T arg, MacroType type, bool expandRecurse)
	{
		if (expandRecurse)
			arg = arg.expandMacroImpl!(T, func)();
		static if (ParameterTypeTuple!Func.length == 1)
		{
			arg = mapFunc(arg);
		}
		else
		{
			arg = mapFunc(arg, type);
		}
		return true;
	}
	
	return str.expandMacroImpl!(T, func)();
}

/// ditto
T expandMacro(T, MAP)(in T str, MAP map)
	if (isSomeString!T
	&& is(typeof({ auto p = T.init in map; T tmp = *p; })))
{
	bool func(ref T arg, MacroType type, bool expandRecurse)
	{
		if (expandRecurse)
			arg = arg.expandMacroImpl!(T, func)();
		if (auto p = arg in map)
		{
			arg = *p;
			return true;
		}
		return false;
	}
	return str.expandMacroImpl!(T, func)();
}


private size_t searchEnd1(Ch)(const(Ch)[] str)
{
	size_t i = 0;
	import std.regex;
	if (auto m = str.matchFirst(ctRegex!(cast(Ch[])`^(?!\d)[a-zA-Z0-9_].*?\b`)))
	{
		return m.hit.length;
	}
	return -1;
}

@system unittest
{
	assert(searchEnd1("abcde-fgh") == 5);
	assert(searchEnd1("abcde$fgh") == 5);
	assert(searchEnd1("abc123de$fgh") == 8);
	assert(searchEnd1("abcde_fgh") == 9);
	assert(searchEnd1("abcde") == 5);
	assert(searchEnd1("abcde789") == 8);
	assert(searchEnd1("789abcde") == -1);
	assert(searchEnd1("$abcde") == -1);
	assert(searchEnd1("") == -1);
}

private size_t searchEnd2(Ch)(const(Ch)[] str, Ch ch)
{
	size_t i = 0;
	while (i < str.length)
	{
		if (str[i] == ch)
			return i;
		if (str[i] == '$')
		{
			if (i+1 < str.length)
			{
				// 連続する$$は無視
				if (str[i+1] == '$')
				{
					i+=2;
					continue;
				}
				if (str[i+1] == '(')
				{
					auto i2 = searchEnd2(str[i+2..$], ')');
					if (i2 == -1)
						return -1;
					i += i2 + 3;
				}
				else if (str[i+1] == '{')
				{
					auto i2 = searchEnd2(str[i+2..$], '}');
					if (i2 == -1)
						return -1;
					i += i2 + 3;
				}
				else
				{
					auto i2 = searchEnd1(str[i+1..$]);
					if (i2 == -1)
						return -1;
					i += i2 + 1;
				}
			}
			else
			{
				return -1;
			}
		}
		else
		{
			++i;
		}
	}
	return -1;
}
@system unittest
{
	assert(searchEnd2("abcde-f)gh", ')') == 7);
	assert(searchEnd2("abcde$f)gh", ')') == 7);
	assert(searchEnd2("abcde_f)gh", ')') == 7);
	assert(searchEnd2("abcde_fgh)", ')') == 9);
	assert(searchEnd2("abcde_$(f)gh)", ')') == 12);
	assert(searchEnd2("abcde_${f}gh)xx", ')') == 12);
}

private T expandMacroImpl(T, alias func)(in T str)
	if (isSomeString!T
	&& isCallable!func
	&& is(ReturnType!func: bool)
	&& ParameterTypeTuple!func.length == 3
	&& is(T:         ParameterTypeTuple!func[0])
	&& is(MacroType: ParameterTypeTuple!func[1])
	&& is(bool:      ParameterTypeTuple!func[2])
	&& (ParameterStorageClassTuple!func[0] & ParameterStorageClass.ref_) == ParameterStorageClass.ref_)
{
	import std.string;
	Appender!T result;
	T rest = str[];
	size_t idxBegin, idxEnd;
	
	while (1)
	{
		idxBegin = rest.representation.countUntil('$');
		if (idxBegin == -1 || idxBegin+1 >= rest.length)
			return result.data ~ rest;
		
		result ~= rest[0..idxBegin];
		
		if (rest[idxBegin+1] == '(')
		{
			auto head = rest[idxBegin..idxBegin+2];
			rest = rest[idxBegin+2..$];
			idxEnd = searchEnd2(rest, ')');
			if (idxEnd == -1)
				return result.data ~ head ~ rest;
			assert(rest[idxEnd] == ')');
			auto tmp = rest[0..idxEnd];
			if (func(tmp, MacroType.expr, true))
			{
				result ~= tmp;
				rest    = rest[idxEnd+1..$];
			}
			else
			{
				result ~= head ~ tmp ~ rest[idxEnd..idxEnd+1];
				rest    = rest[idxEnd+1..$];
			}
		}
		else if (rest[idxBegin+1] == '{')
		{
			auto head = rest[idxBegin..idxBegin+2];
			rest = rest[idxBegin+2..$];
			idxEnd = searchEnd2(rest, '}');
			if (idxEnd == -1)
				return result.data ~ head ~ rest;
			assert(rest[idxEnd] == '}');
			auto tmp = rest[0..idxEnd];
			if (func(tmp, MacroType.str, true))
			{
				result ~= tmp;
				rest    = rest[idxEnd+1..$];
			}
			else
			{
				result ~= head ~ tmp ~ rest[idxEnd..idxEnd+1];
				rest    = rest[idxEnd+1..$];
			}
		}
		else if (rest[idxBegin+1] == '$')
		{
			result ~= rest[idxBegin+1];
			rest = rest[idxBegin+2..$];
		}
		else
		{
			auto head = rest[idxBegin..idxBegin+1];
			rest = rest[idxBegin+1..$];
			idxEnd = searchEnd1(rest);
			if (idxEnd == -1)
				return result.data ~ rest;
			auto tmp = rest[0..idxEnd];
			if (func(tmp, MacroType.str, false))
			{
				result ~= tmp;
				rest    = rest[idxEnd..$];
			}
			else
			{
				result ~= head ~ tmp;
				rest    = rest[idxEnd..$];
			}
		}
	}
	assert(0);
}

@system unittest
{
	import std.meta;
	assert("x${$(aaa)x}${$(aaa)y}".expandMacro(["aaa": "AAA", "AAAx": "BBB"]) == "xBBB${AAAy}");
	static foreach (T; AliasSeq!(string, wstring, dstring))
	{{
		T str = "test$(xxx)${zzz}test$$${yyy}";
		T[T] map = ["xxx": "XXX", "yyy": "YYY"];
		assert(str.expandMacro(map) == "testXXX${zzz}test$YYY");
		assert(expandMacro(cast(T)"test$(yyy", map) == "test$(yyy");
		assert(expandMacro(cast(T)"test${zzz", map) == "test${zzz");
		
		auto foo = function T(T arg)
		{
			if (arg == cast(T)"xxx")
				return cast(T)"XXX";
			if (arg == cast(T)"abcXXX")
				return cast(T)"yyy";
			return cast(T)"ooo";
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", foo) == "xxxoooyyy");
		assert(expandMacro(cast(T)"xxあいうえおx$yyy$(abc${xxx})", foo) == "xxあいうえおxoooyyy");
		
		auto bar = delegate bool(ref T arg)
		{
			if (arg == cast(T)"xxx")
			{
				arg = cast(T)"XXX";
				return true;
			}	
			if (arg == cast(T)"abcXXX")
			{
				arg = cast(T)"yyy";
				return true;
			}
			return false;
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", bar) == "xxx$yyyyyy");
		assert(expandMacro(cast(T)"xxx$(aaa)", bar) == "xxx$(aaa)");
		assert(expandMacro(cast(T)"xxx$$(aaa)", bar) == "xxx$(aaa)");
		assert(expandMacro(cast(T)"xxx$(a$$aa)", bar) == "xxx$(a$aa)");
		assert(expandMacro(cast(T)"xxx$(a$(aa", bar) == "xxx$(a$(aa");
		assert(expandMacro(cast(T)"xxx$(a$...", bar) == "xxx$(a$...");
		assert(expandMacro(cast(T)"xxx$(a$", bar) == "xxx$(a$");
		
		auto foo2 = function T(T arg, MacroType ty)
		{
			if (arg == cast(T)"xxx")
				return ty == MacroType.str ? cast(T)"XXX1" : cast(T)"XXX2";
			if (arg == cast(T)"abcXXX1")
				return ty == MacroType.str ? cast(T)"yyy1" : cast(T)"yyy2";
			return ty == MacroType.str ? cast(T)"ooo1" : cast(T)"ooo2";
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", foo2) == "xxxooo1yyy2");
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx}", foo2) == "xxxooo1$(abc${xxx}");
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx", foo2) == "xxxooo1$(abc${xxx");
		assert(expandMacro(cast(T)"xxx$...", foo2) == "xxx...");
		
		auto bar2 = delegate bool(ref T arg, MacroType ty)
		{
			if (arg == cast(T)"xxx")
			{
				arg = ty == MacroType.str ? cast(T)"XXX1" : cast(T)"XXX2";
				return true;
			}	
			if (arg == cast(T)"abcXXX1")
			{
				arg = ty == MacroType.str ? cast(T)"yyy1" : cast(T)"yyy2";
				return true;
			}
			return false;
		};
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx})", bar2) == "xxx$yyyyyy2");
		assert(expandMacro(cast(T)"xxx$yyy$(abc${xxx}", bar2) == "xxx$yyy$(abc${xxx}");
		assert(expandMacro(cast(T)"xあいうえおxx$yyy$(abc${xxx}", bar2) == "xあいうえおxx$yyy$(abc${xxx}");
	}}
}


/*******************************************************************************
 * 文字列内に含まれる変数を展開します。
 * 
 * `aaa%VAR%bbb`のVAR変数を展開します。変数が存在しない場合は何もしません。
 * VARがxxxであれば、`aaaxxxbbb`となります。
 * VARが存在しなければ、`aaa%VAR%bbb`のままです。
 */
T expandVariable(T, MAP)(in T str, MAP map)
	if (isSomeString!T
	&& is(typeof({ auto p = T.init in map; T var = *p; })))
{
	bool func(ref T arg)
	{
		if (auto p = arg in map)
		{
			arg = *p;
			return true;
		}
		return false;
	}
	return expandVariableImpl!(T, func)(str);
}
/// ditto
T expandVariable(T, Func)(in T str, Func mapFunc)
	if (isSomeString!T
	&& isCallable!Func
	&& is(ReturnType!Func: T)
	&& ParameterTypeTuple!Func.length == 1
	&& is(T: ParameterTypeTuple!Func[0]))
{
	bool func(in T arg)
	{
		arg = mapFunc(arg);
		return ture;
	}
	return expandVariableImpl!(T, func)(str);
}

private T expandVariableImpl(T, alias func)(in T str)
	if (isSomeString!T
	&& isCallable!func
	&& is(ReturnType!func: bool)
	&& ParameterTypeTuple!func.length == 1
	&& is(ParameterTypeTuple!func[0] == T)
	&& (ParameterStorageClassTuple!func[0] & ParameterStorageClass.ref_) == ParameterStorageClass.ref_)
{
	Appender!T result;
	T rest = str[];
	size_t idxBegin, idxEnd;
	while (1)
	{
		idxBegin = rest.countUntil('%');
		
		if (idxBegin == -1 || idxBegin+1 >= rest.length)
			return result.data ~ rest;
		
		idxEnd = rest[idxBegin+1..$].countUntil('%');
		if (idxEnd == -1)
			return result.data ~ rest;
		
		idxEnd += idxBegin+2;
		if (idxBegin+2 == idxEnd)
		{
			result ~= rest[0..idxBegin+1];
			rest    = rest[idxEnd..$];
		}
		else
		{
			auto tmp = rest[idxBegin+1 .. idxEnd-1];
			if (func(tmp))
			{
				result ~= rest[0..idxBegin] ~ tmp;
				rest    = rest[idxEnd..$];
			}
			else
			{
				result ~= rest[0..idxBegin+1] ~ tmp;
				rest    = rest[idxEnd-1..$];
			}
		}
	}
	assert(0);
}
@system unittest
{
	import std.meta;
	static foreach (T; AliasSeq!(string, wstring, dstring))
	{{
		T str = "test%xxx%te%%st%yyy%";
		T[T] map = ["xxx": "XXX"];
		assert(str.expandVariable(map) == "testXXXte%st%yyy%");
	}}
}


/*******************************************************************************
 * 
 */
struct RotationSerial(T, T start = T.min + 1, T end = T.max)
if (isIntegral!T && isUnsigned!T)
{
@safe pure nothrow @nogc:
	/***************************************************************************
	 * 
	 */
	enum min = RotationSerial(start);
	
	/***************************************************************************
	 * 
	 */
	enum max = RotationSerial(end - 1);
	
private:
	T _value;
	
	static T add(T a, T b)
	{
		enum maxv = max._value;
		enum minv = min._value;
		auto c = cast(T)(a + b);
		if (c < a)
			return cast(T)(minv + ((T.max - maxv) + c));
		if (c < end)
			return c;
		return cast(T)(minv + (c - end));
	}
public:
	
	/***************************************************************************
	 * 
	 */
	this(T val)
	{
		_value = val;
	}
	
	/***************************************************************************
	 * 
	 */
	bool isUninitialized() const
	{
		return _value == RotationSerial.init._value;
	}
	
	/***************************************************************************
	 * 
	 */
	bool isValid() const
	{
		return start <= _value && _value < end;
	}
	
	
	/***************************************************************************
	 * 
	 */
	T value() const
	{
		return value;
	}
	
	/***************************************************************************
	 * 
	 */
	ref RotationSerial opUnary(string op)()
	if (op == "++")
	{
		if (_value < max._value)
		{
			++_value;
		}
		else
		{
			_value = min._value;
		}
		return this;
	}
	
	/***************************************************************************
	 * 
	 */
	int opCmp(RotationSerial rhs) const
	{
		enum center = cast(T)((max._value - min._value) / 2);
		if (rhs._value == _value)
			return 0;
		auto pod = add(_value, center);
		
		if (_value < pod)
		{
			// l   p   r  :  r < l ... 1
			if (pod < rhs._value)
				return +1;
			// l   r   p  :  l < r ... -1
			// r   l   p  :  r < l ... 1
			return _value < rhs._value ? -1 : +1;
		}
		else
		{
			// r   p   l  :  l < r ... -1
			if (rhs._value < pod)
				return -1;
			// p   l   r  :  l < r ... -1
			// p   r   l  :  r < l ... 1
			return _value < rhs._value ? -1 : +1;
		}
	}
	
}

///
@safe unittest
{
	// シリアル値。範囲は10～249の間で、ローテーションする
	alias SerialNum = RotationSerial!(ubyte, 10, 250);
	
	// シリアル値はインクリメントで値が増加する
	auto ser = SerialNum(10);
	++ser;
	assert(ser > SerialNum(10));
	assert(ser == SerialNum(11));
	
	// 値の範囲の終端まで行くとローテーションする
	// ローテーションしても、ローテーション前の値よりは大きくなるという判定を行う。
	ser = SerialNum(249);
	++ser;
	assert(ser > SerialNum(249));
	assert(ser == SerialNum(10));
}

@safe unittest
{
	alias Ser = RotationSerial!(ubyte, 10, 250);
	assert(Ser.add(150, 200) == 110);
	assert(Ser.add(150, 99) == 249);
	assert(Ser.add(150, 100) == 10);
	assert(Ser.add(150, 101) == 11);
	assert(Ser.add(150, 102) == 12);
	assert(Ser.add(150, 103) == 13);
	assert(Ser.add(150, 104) == 14);
	assert(Ser.add(150, 105) == 15);
	assert(Ser.add(150, 106) == 16);
	
	auto x1 = Ser(10);
	auto x2 = Ser(50);
	auto x3 = Ser(128);
	auto x4 = Ser(129);
	auto x5 = Ser(130);
	auto x6 = Ser(200);
	auto x7 = Ser(249);
	assert(x1 == x1);
	assert(x1 < x2);
	assert(x1 < x3);
	assert(x1 < x4);
	assert(x1 > x5);
	assert(x1 > x6);
	assert(x1 > x7);
	
	assert(x7 < x1);
	assert(x7 < x2);
	assert(x7 > x3);
	assert(x7 > x4);
	assert(x7 > x5);
	assert(x7 > x6);
	assert(x7 == x7);
}

/*******************************************************************************
 * Create combinations matrix from specified lists of conditional patterns
 * 
 * Params:
 *      matrix   = Matrix of conditional patterns. $(BR)
 *                 ex; Input   `[["1", "2"], ["A", "B"]]` $(BR)
 *                     Results `[["1", "A"], ["1", "B"], ["2", "A"], ["2", "B"]]`
 *      matrixAA = Matrix of conditional patterns. For each column, the name is represented by an associative array key. $(BR)
 *                 ex; Input   `["P1": ["1", "2"], "P2": ["A", "B"]]` $(BR)
 *                     Results `[["P1": "1", "P2": "A"], ["P1": "1", "P2": "B"], ["P1": "2", "P2": "A"], ["P1": "2", "P2": "B"]]`
 * Returns:
 *      Matrix of combination
 */
auto combinationMatrix(R)(R matrix)
if (isInputRange!R && isInputRange!(ElementType!R))
{
	import std.typecons: tuple;
	
	if (matrix.empty)
		return null;
	auto ary = matrix.front.map!(a=>[a]).array;
	matrix.popFront();
	foreach (elm; matrix)
		ary = cartesianProduct(ary, elm).map!(a => a[0] ~ [a[1]]).array;
	
	return ary;
}

///
@safe unittest
{
	assert(combinationMatrix([["a", "b"], ["A", "B", "C"], ["1", "2"]]).equal([
		["a", "A", "1"],
		["a", "A", "2"],
		["a", "B", "1"],
		["a", "B", "2"],
		["a", "C", "1"],
		["a", "C", "2"],
		["b", "A", "1"],
		["b", "A", "2"],
		["b", "B", "1"],
		["b", "B", "2"],
		["b", "C", "1"],
		["b", "C", "2"],
	]));
}

/// ditto
auto combinationMatrix(K,R)(R[K] matrixAA)
if (isInputRange!R)
{
	import std.typecons: tuple;
	
	return matrixAA.byKeyValue
		.map!(vPair => vPair.value.map!(v => tuple(vPair.key, v)))
		.combinationMatrix.map!(a => assocArray(a));
}
///
@safe unittest
{
	assert(combinationMatrix(["P1": ["a", "b"], "P2": ["A", "B", "C"], "P3": ["1", "2"]]).equal([
		["P1": "a", "P2": "A", "P3": "1"],
		["P1": "a", "P2": "A", "P3": "2"],
		["P1": "a", "P2": "B", "P3": "1"],
		["P1": "a", "P2": "B", "P3": "2"],
		["P1": "a", "P2": "C", "P3": "1"],
		["P1": "a", "P2": "C", "P3": "2"],
		["P1": "b", "P2": "A", "P3": "1"],
		["P1": "b", "P2": "A", "P3": "2"],
		["P1": "b", "P2": "B", "P3": "1"],
		["P1": "b", "P2": "B", "P3": "2"],
		["P1": "b", "P2": "C", "P3": "1"],
		["P1": "b", "P2": "C", "P3": "2"],
	]));
}


/*******************************************************************************
 * Shuffle elements of specified range
 */
auto shuffle(R)(R ary)
if (isRandomAccessRange!R)
{
	import std.random: uniform;
	auto idx = iota(0, ary.length).array;
	foreach (i; 0..ary.length)
		swap(idx[i], idx[uniform(i, ary.length)]);
	return indexed(ary, idx);
}


/*******************************************************************************
 * Check if the SumType contains a value
 */
T get(T, ST)(ref ST value, lazy T defaultValue = T.init) @trusted
if (isSumType!ST)
{
	return value.match!(
		(ref T v) => v,
		(ref _) => defaultValue
	);
}
/// ditto
const(T) get(T, ST)(in ST value, lazy T defaultValue = T.init) @trusted
if (isSumType!ST)
{
	return value.match!(
		(in T v) => v,
		(in _) => defaultValue
	);
}

@system unittest
{
	SumType!(int, string, bool) v;
	assert(v.get!bool == false);
	v = 10;
	assert(v.get!int == 10);
	v = "abc";
	assert(v.get!string == "abc");
	v = true;
	assert(v.get!bool == true);
	assert(v.get!string("xxx") == "xxx");
}


/*******************************************************************************
 * 最短編集スクリプトを計算して探索経路を記録
 * 
 * 最短編集系列（SES）の探索本体。各 D（編集回数）ごとの最遠到達点Vを保存する。
 * Params:
 *       lhs = 編集前入力シーケンス, 必ず1つ以上の要素を持つ
 *       rhs = 編集後入力シーケンス, 必ず1つ以上の要素を持つ
 *       trace = V配列のスナップショット配列(出力用)
 * Returns: 編集距離 D (0..N+M) = 追加(insert)と削除(remove) の累計数
 * Annotations : traceの各要素は int配列(長さ: 2*max+1)。
 */
private int _shortestEditScript(Range)(in Range lhs, in Range rhs, ref int[][] trace) @safe
if (isRandomAccessRange!Range || isSomeString!Range)
in (!lhs.empty)
in (!rhs.empty)
{
	immutable int n = cast(int) lhs.length;
	immutable int m = cast(int) rhs.length;
	immutable int maxd = n + m;
	immutable int offset = maxd;
	immutable int width  = 2 * maxd + 1;
	
	int[] v = new int[width];
	v[0..offset] = -1;               // センチネルは -1
	
	for (int d = 0; d <= maxd; ++d) {
		auto prev = v.dup;  // 前回スナップショット

		for (int k = -d; k <= d; k += 2) {
			const int kIndex = offset + k;

			int x;
			// 参照は必ず prev から
			if (k == -d || (k != d && prev[kIndex - 1] < prev[kIndex + 1])) {
				// 挿入（down）：k+1 から来る
				x = prev[kIndex + 1];
			} else {
				// 削除（right）：k-1 から来る
				x = prev[kIndex - 1] + 1;
			}
			int y = x - k;

			// スネーク
			while (x < n && y < m && lhs[x] == rhs[y]) {
				++x; ++y;
			}
			v[kIndex] = x;

			if (x >= n && y >= m) {
				trace ~= v.dup;   // バックトラック用に保存
				return d;
			}
		}
		trace ~= v.dup;
	}
	assert(0, "Unreachable");
}

@system unittest
{
	int[][] trace;
	alias check = (lhs, rhs, int expectD)
	{
		import std.format;
		// lhs, rhsはテンプレート(どんな型にもマッチ)
		trace.length = 0;
		int d = _shortestEditScript(lhs, rhs, trace);
		assert(d == expectD, format("shortestEditScript failed for %s -> %s %d", lhs, rhs, d));
	};

	check("abc", "abc", 0);          // 完全一致
	check("abc", "axc", 2);          // 1文字置換
	check("abc", "abcd", 1);         // 末尾に追加
	check("abcd", "abc", 1);         // 末尾を削除
	check("kitten", "sitting", 5);   // Levenshtein距離で有名な例
	check("aaaa", "bbbb", 8);        // 全置換
	check("abcdef", "abqdef", 2);    // 中間1文字置換
	check("abcdef", "azced", 5);     // 部分一致＋置換
	check(["aaa", "bb", "c"], ["aa", "bb", "cc"], 4); // 文字列のリストでの比較
	check("a", "b", 2);                  // 最小単位の変換
	check("longtext", "long", 4);        // 末尾削除多数
	check("long", "longtext", 4);        // 末尾追加多数
}


/*******************************************************************************
 * trace を逆にたどって操作ステップ列を生成
 * 
 * 前進探索で保存した trace を用いて、編集ステップ列（前方向）を復元する
 * 
 * Params:
 *       lhs = 編集前入力シーケンス, 必ず1つ以上の要素を持つ
 *       rhs = 編集後入力シーケンス, 必ず1つ以上の要素を持つ
 *       trace = _shortestEditScript で得た配列
 *       dResult = _shortestEditScript の計算結果の編集距離 D
 * Returns: 編集操作のリスト。追加(insert), 削除(remove), 変更なし(none) のみ。
 */
private EditOp[] _backtrackSteps(Range)(in Range lhs, in Range rhs, const ref int[][] trace, int dResult) @safe
if (isRandomAccessRange!Range || isSomeString!Range)
in (!lhs.empty)
in (!rhs.empty)
{
	const size_t n = lhs.length;
	const size_t m = rhs.length;

	int x = cast(int)n;
	int y = cast(int)m;
	EditOp[] reversedSteps;

	if (dResult < 0 || trace.length == 0)
	{
		return [];
	}

	// trace[d] が存在する前提で、配列幅から offset を決める（安全策）
	// v の長さ = 2*offset + 1 と仮定 -> offset = (len - 1) / 2
	int globalOffset = (cast(int)trace[dResult].length - 1) / 2;

	// d を下っていく（dResult .. 1）。d==0 は最後の対角だけ残す扱いにする。
	for (int d = dResult; d > 0; --d)
	{
		// 現在の k（現在位置の対角）
		int k = x - y;

		// 前のレベルの v を参照
		auto vPrev = trace[d - 1];
		int prevOffset = (cast(int)vPrev.length - 1) / 2;

		// decide: 挿入 (came from k+1) か 削除 (came from k-1) か
		bool cameFromInsert;
		if (k == -d)
		{
			cameFromInsert = true;
		}
		else if (k == d)
		{
			cameFromInsert = false;
		}
		else
		{
			// 比較は vPrev[k-1] < vPrev[k+1] なら挿入（Myersの条件）
			int idxLeft  = prevOffset + (k - 1);
			int idxRight = prevOffset + (k + 1);
			// （安全のための境界チェックを入れても良いが、trace の作り次第）
			cameFromInsert = vPrev[idxLeft] < vPrev[idxRight];
		}

		int prevK;
		int prevX; // = vPrev[prevK]
		int prevY; // = prevX - prevK
		EditOp edit;

		if (cameFromInsert)
		{
			prevK = k + 1;
			prevX = vPrev[prevOffset + prevK];
			prevY = prevX - prevK;
			edit = EditOp.insert;
		}
		else
		{
			prevK = k - 1;
			prevX = vPrev[prevOffset + prevK];
			prevY = prevX - prevK;
			edit = EditOp.remove;
		}

		// prevX/prevY が「d-1 レベルでの座標 (x_prev, y_prev)」
		// 今の位置 (x, y) から prev に向けて対角（一致）を出力
		while (x > prevX && y > prevY)
		{
			reversedSteps ~= EditOp.none;
			--x;
			--y;
		}

		// 非対角移動（挿入 or 削除）を追加して、座標を prev に戻す
		reversedSteps ~= edit;
		x = prevX;
		y = prevY;
	}

	// d == 0 レベルで残った対角 (先頭の一致) を追加
	while (x > 0 && y > 0)
	{
		reversedSteps ~= EditOp.none;
		--x;
		--y;
	}

	// 逆向きに貯めてあるので反転して返す
	return reversedSteps.reverse;
}



@safe unittest
{
	import std.format : format;
	
	EditOp[] ops(string opstr) @trusted => cast(EditOp[])opstr.dup;
	int[][] trace;
	alias check = (lhs, rhs, expect)
	{
		trace.length = 0;
		int d = _shortestEditScript(lhs, rhs, trace);
		auto steps = _backtrackSteps(lhs, rhs, trace, d);
		assert(steps == expect,
			format!"backtrackSteps failed: %s -> %s, got %s, expected %s"(lhs, rhs, steps, expect));
	};

	// --- backtrackSteps のテストケース ---
	check("abc", "abc", ops("nnn"));
	check("abc", "axc", ops("nrin"));
	check("abc", "abcd", ops("nnni"));
	check("abcd", "abc", ops("nnnr"));
	check("a", "b", ops("ri"));
	check("ab", "ba", ops("rni"));  // 転置的な場合
	check("kitten", "sitting", ops("rinnnrini"));   // 結果は距離に応じて長い、ここでは成功すればOK
	check("abcdef", "azced", ops("nrinrnri"));      // 複雑例
	check("a", "aa", ops("ni"));    // 末尾追加
	check("aa", "a", ops("nr"));    // 末尾削除
}

/*******************************************************************************
 * 編集操作出力
 * 
 * ステップ列を走査し、置換(substitute)を畳み込みながら最終操作列を生成。
 * 1文字操作 remove(削除) と insert(追加) の並びをペアリングして
 * substitute(変更) を生成し、none（一致）はそのまま出力する。
 * 具体的には、前方向のインデックス (i,j) を進めながら、
 * - 一致セグメントは none を連続出力
 * - 直後の remove と insert のペア（順不同）を一つの substitute に畳み込み
 * - 余った単独の remove / insert はそのまま出力
 * Params:
 *       lhs = 編集前入力シーケンス
 *       rhs = 編集後入力シーケンス
 *       steps = backtrackSteps が返すステップ列 (none, remove, insert)
 * Returns: 実際に出力すべき総文字数（バッファより長い場合は切り詰め書き込み）
 */
private EditOp[] _emitOpsCollapseSubst(Range)(in Range lhs, in Range rhs, in EditOp[] steps) @safe
if (isRandomAccessRange!Range || isSomeString!Range)
in (!lhs.empty)
in (!rhs.empty)
{
	size_t i = 0;
	size_t j = 0;
	EditOp[] ops;

	size_t p = 0;
	while (p < steps.length)
	{
		EditOp step = steps[p];
		
		if (step == EditOp.none)
		{
			ops ~= EditOp.none;
			++i;
			++j;
			++p;
			continue;
		}
		
		if (step == EditOp.remove || step == EditOp.insert)
		{
			// remove/insert のブロックをまとめる
			size_t removeCount = 0;
			size_t insertCount = 0;
			
			size_t q = p;
			while (q < steps.length && (steps[q] == EditOp.remove || steps[q] == EditOp.insert))
			{
				if (steps[q] == EditOp.remove)
					++removeCount;
				else
					++insertCount;
				++q;
			}
			
			// ペア部分は substitute
			size_t substCount = (removeCount < insertCount) ? removeCount : insertCount;
			foreach (_; 0 .. substCount)
			{
				ops ~= EditOp.substitute;
				++i;
				++j;
			}
			
			// 余りの remove
			foreach (_; substCount .. removeCount)
			{
				ops ~= EditOp.remove;
				++i;
			}
			
			// 余りの insert
			foreach (_; substCount .. insertCount)
			{
				ops ~= EditOp.insert;
				++j;
			}
			
			p = q;
			continue;
		}
		
		// 不明なステップが混ざった場合（通常はありえない）
		++p;
	}

	return ops;
}

@safe unittest
{
	import std.format : format;
	
	EditOp[] ops(string opstr) @trusted => cast(EditOp[])opstr.dup;
	alias check = (lhs, rhs, EditOp[] steps, EditOp[] expect) {
		int[][] trace;
		trace.length = 0;
		auto ops = _emitOpsCollapseSubst(lhs, rhs, steps);
		assert(ops == expect,
			format!"emitOpsCollapseSubst failed: %s -> %s, got %s, expected %s"(lhs, rhs, ops, expect));
	};
	
	check("abc", "abc", ops("nnn"), ops("nnn"));
	check("abc", "axc", ops("nrin"), ops("nsn")); // r+i → substitute
	check("abc", "abcd", ops("nnni"), ops("nnni"));
	check("abcd", "abc", ops("nnnr"), ops("nnnr"));
	check("a", "b", ops("ri"), ops("s"));
	check("aaaa", "bbbb", ops("rrrriiii"), ops("ssss"));
	check("abcdef", "abqdef", ops("nnrinnn"), ops("nnsnnn"));
	check("abcdef", "azced", ops("nrinrnri"), ops("nsnrns"));
	check("a", "aa", ops("ni"), ops("ni"));
	check("aa", "a", ops("nr"), ops("nr"));
	
	
	check("abc", "abc", ops("nnn"), ops("nnn"));    // 一致のみ（none のみ）
	check("abc", "adc", ops("nrin"), ops("nsn"));   // 1文字置換 / b削除→d追加のステップ -> substitute に畳み込み
	check("abc", "xyz", ops("rrriii"), ops("sss")); // 全部置換 → substitute連発 / 3削除 + 3挿入 -> 3置換
	check("ab", "abxy", ops("nnii"), ops("nnii"));  // 追加のみ
	check("abcd", "ab", ops("nnrr"), ops("nnrr"));  // 削除のみ
	// 複数削除の後に複数挿入 → substitute + 余り / x,y,z削除 → 1,2挿入 -> substitute2個 + insert + none2個
	check("wxyz", "wab12z", ops("nrriiiin"), ops("nssiin"));
	// remove, insert が交互に出る場合 → substitute にまとめる / p削除,r追加,q削除,s追加 -> substitute2個
	check("pq", "rs", ops("riri"), ops("ss"));
}

/*******************************************************************************
 * Myers' diff
 * 
 * lhs を rhs に変換する操作列を返す
 * Params:
 *      lhs = 編集前入力シーケンス
 *      rhs = 編集後入力シーケンス
 *      calcCollapseSubStitute = trueの場合、戻り値にEditOp.substituteが含まれるようになる
 * Returns:
 *      編集操作列(EditOpの配列)
 */
EditOp[] myersdiff(bool calcCollapseSubStitute = false, Range)(Range lhs, Range rhs)
if (isRandomAccessRange!Range || isSomeString!Range)
{
	const size_t n = lhs.length;
	const size_t m = rhs.length;
	
	if (n == 0 && m == 0)
		return [];
	if (n == 0)
		return EditOp.insert.repeat(m).array;
	if (m == 0)
		return EditOp.remove.repeat(n).array;
	int[][] trace;
	int dResult = _shortestEditScript(lhs, rhs, trace);
	static if (!calcCollapseSubStitute)
	{
		return _backtrackSteps(lhs, rhs, trace, dResult);
	}
	else
	{
		EditOp[] steps = _backtrackSteps(lhs, rhs, trace, dResult);
		return _emitOpsCollapseSubst(lhs, rhs, steps);
	}
}

/// ditto
alias diff = myersdiff;
